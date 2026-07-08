#!/usr/bin/env python3
"""实时翻译消费者（增量翻译 + 命中式术语注入）。

架构：
  主线程读 events.jsonl → classify_update() 判定增量模式 → 翻译 → 输出
  partial 模式：后台翻译线程异步处理，不阻塞主线程

增量模式：
  append_only     — 新文本只是旧文本的尾巴，只翻增量
  small_rewrite_tail — 前面一致，尾部小改写，翻增量
  reset_full      — 差异太大，整段重翻

用法：
  python3 src/translate_stream.py \
    --events runs/smoke5min/events.jsonl \
    --out-dir runs/smoke5min \
    --mode partial
"""

import argparse
import json
import os
import sys
import threading
import time
import datetime
from queue import Queue, Empty

from translator_hy_mt2 import (
    HyMT2Translator, classify_update, detect_language, detect_glossary_hits,
    set_scene_context, _strip_prompt_leak,
)
from languages import normalize_target_language, TargetLanguage


# ── 共享文件 I/O ─────────────────────────────────────────────────────────────
# lang_config.json 是 macui 设置界面和 Python 后端**共享**的文件。
# 写盘要保证原子性（写临时文件 → fsync → 原子替换），避免 macui 端读到
# 半写状态。也避免后端崩溃留下 .tmp 临时文件（崩溃前如果只完成了第一步
# 就死了，原文件还在，临时文件残留但下次启动会被清掉）。

def _atomic_write_json(path: str, obj) -> None:
    """原子地把 obj 写成 JSON 到 path。

    流程：写 path + ".tmp" → flush + fsync → rename 替换原文件。
    如果原文件存在，rename 在同 inode 上原地完成（保持 macui 端
    文件监视器有效）；如果不存在则创建新文件。
    """
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


# ── 输出过滤 ────────────────────────────────────────────────────────────────────

_EXPLANATION_PATTERNS = [
    "here is the translation",
    "the translation is",
    "translated text",
    "翻译如下",
    "译文如下",
    "以下是翻译",
]

_CONTEXT_ECHO_PATTERNS = [
    "最近上下文",
    "最近的相关",
    "最近的情况",
    "最近的背景",
    "最近的热门",
    "仅供参考，不要重复",
    "仅供参考，请勿重复",
    "英文前文",
    "中文前文",
    "前文衔接",
]


def _is_explanation(text: str) -> bool:
    lower = text.strip().lower()
    if any(lower.startswith(p) for p in _EXPLANATION_PATTERNS):
        return True
    if any(p in text[:200] for p in _CONTEXT_ECHO_PATTERNS):
        return True
    return False


# ── 格式化 ──────────────────────────────────────────────────────────────────────

def _format_time(sec: float) -> str:
    m, s = divmod(int(sec), 60)
    return f"{m:02d}:{s:02d}"


def _bilingual_line(event: dict, zh_text: str) -> str:
    t_start = _format_time(event.get("audio_start_sec", 0))
    t_end = _format_time(event.get("audio_end_sec", 0))
    en = event.get("text", "").strip()
    return f"[{t_start} → {t_end}]  {en}\n  → {zh_text}\n"


def _source_key(event: dict) -> str:
    return f"{event['seg_start']}-{event['seg_end']}-{event.get('audio_end_sec', 0)}"


def resolve_target_lang(source_text: str, target_lang: str | None) -> str:
    """根据源文本和目标语言配置，解析出实际的 target_lang prompt_name。

    target_lang=None 或 "auto" 时自动检测：中文→English，其他→Simplified Chinese。
    否则使用用户指定的语言。
    """
    if target_lang is None or target_lang == "auto":
        src_lang = detect_language(source_text)
        return "English" if src_lang == "zh" else "Simplified Chinese"
    return target_lang


def _log_glossary_hits(translator, source_text: str, target_lang: str):
    """检测并打印词库命中，同时更新命中计数。"""
    glossary = getattr(translator, "glossary", {})
    if not glossary:
        return
    hits = detect_glossary_hits(source_text, glossary, target_lang)
    if hits:
        terms = ", ".join(f"{k}→{v}" for k, v in list(hits.items())[:6])
        print(f"[glossary] 命中 {len(hits)} 个术语: {terms}", flush=True)
        # 更新命中元数据（内存中，定期刷盘）
        _track_hits(translator.glossary_path, glossary, hits)


_glossary_hits_buffer: dict[str, int] = {}
_glossary_flush_counter = 0
GLOSSARY_FLUSH_INTERVAL = 50  # 每 50 次命中刷盘一次


def _track_hits(glossary_path: str | None, glossary: dict, hits: dict):
    """在内存中累计命中次数，定期写回 glossary.json。"""
    global _glossary_flush_counter
    now_str = time.strftime("%Y-%m-%d %H:%M:%S")
    meta = glossary.setdefault("_meta", {})
    for term in hits:
        if term not in meta:
            meta[term] = {"source": "unknown", "added": now_str, "last_used": now_str, "hits": 1}
        else:
            meta[term]["last_used"] = now_str
            meta[term]["hits"] = meta[term].get("hits", 0) + 1
        _glossary_hits_buffer[term] = _glossary_hits_buffer.get(term, 0) + 1

    _glossary_flush_counter += len(hits)
    if _glossary_flush_counter >= GLOSSARY_FLUSH_INTERVAL:
        _flush_glossary_meta(glossary_path, glossary)
        _glossary_flush_counter = 0


def _flush_glossary_meta(glossary_path: str | None, glossary: dict):
    """将内存中的命中计数刷到 glossary.json。"""
    if not glossary_path:
        return
    try:
        import json as _json
        tmp = glossary_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            _json.dump(glossary, f, ensure_ascii=False, indent=2)
            f.write("\n")
        os.replace(tmp, glossary_path)
    except Exception:
        pass


# ── 增量翻译状态 ────────────────────────────────────────────────────────────────

class TranslationState:
    """维护增量翻译的源/目标缓冲区。"""

    def __init__(self, target_lang: str | None = None):
        self.last_source_text: str = ""
        self.last_translated_text: str = ""
        self.last_source_key: str = ""
        self.target_lang = target_lang  # None = auto

    def classify(self, new_source: str) -> dict:
        """判定 new_source 相对于 last_source_text 的更新模式。"""
        return classify_update(self.last_source_text, new_source)

    def translate_final(self, translator, new_source: str, update_info: dict,
                        event: dict, counts: dict) -> dict | None:
        """增量翻译一条 final 事件。返回输出事件 dict，或 None 表示跳过。"""
        mode = update_info["mode"]
        delta = update_info["delta_source_text"]
        t0 = time.monotonic()

        if mode == "reset_full":
            return self._do_full(translator, new_source, event, counts, t0, mode)

        if not delta:
            # 文本没变化，跳过
            return None

        return self._do_delta(translator, delta, event, counts, t0, mode, update_info)

    def _do_delta(self, translator, delta, event, counts, t0, mode, update_info):
        prev_src_tail = self.last_source_text[-40:] if self.last_source_text else ""
        prev_tgt_tail = self.last_translated_text[-20:] if self.last_translated_text else ""
        target_lang = resolve_target_lang(delta, self.target_lang)
        try:
            delta_zh, translate_ms, meta = translator.translate_delta(
                delta, prev_source_tail=prev_src_tail, prev_target_tail=prev_tgt_tail,
                target_lang=target_lang,
            )
        except Exception as exc:
            counts["errors"] += 1
            return self._error_event(event, delta, str(exc))

        if _is_explanation(delta_zh):
            # 增量输出异常 → fallback 全量重翻
            counts["fallbacks"] += 1
            return self._do_full(translator, event.get("text", ""), event, counts, t0, "reset_full",
                                 fallback_reason=f"bad_delta_output: {delta_zh[:40]}")

        if mode == "append_only":
            merged_zh = self.last_translated_text + delta_zh
        elif mode == "small_rewrite_tail":
            # 跨语言字符比例不稳定，用整段拼接（重翻 delta 部分，拼上前缀）
            merged_zh = self.last_translated_text + delta_zh
        else:
            merged_zh = delta_zh

        # 最终 prompt leak 兜底：translator.translate_delta 内部已
        # _strip_prompt_leak，但只剥 delta_zh 开头。我们再检查 merged_zh
        # 整体——如果包含 `_PROMPT_LABEL_LEAKS` 列表里的关键字（"只输出翻译结果"、
        # "请只输出翻译"等），整条 final drop，避免把翻译器自己的 prompt
        # 文本当字幕显示。
        cleaned_zh, leak_hit = _strip_prompt_leak(merged_zh)
        if leak_hit:
            with self.out_lock:
                key = _source_key(event)
                print(
                    f"\r\033[K[warn] drop leak final (delta) @ {key} "
                    f"src={event.get('text', '')[:50]!r}",
                    flush=True,
                )
            self.counts["leak_drops"] = self.counts.get("leak_drops", 0) + 1
            return None
        merged_zh = cleaned_zh

        self.last_source_text = event.get("text", "")
        self.last_translated_text = merged_zh
        self.last_source_key = _source_key(event)
        counts["translated"] += 1
        counts["deltas"] += 1

        return {
            "event_type": "translation_final",
            "source_key": _source_key(event),
            "source_update_mode": mode,
            "source_text": event.get("text", ""),
            "delta_source_text": delta,
            "translated_delta_text": delta_zh,
            "translated_full_text": merged_zh,
            "translate_ms": round(translate_ms, 1),
            "shared_prefix_len": update_info["shared_prefix_len"],
            "glossary_hits": meta.get("glossary_hits", []),
            "retried": meta.get("retried", False),
            "fallback_reason": "",
        }

    def _do_full(self, translator, new_source, event, counts, t0, mode,
                 fallback_reason=""):
        target_lang = resolve_target_lang(new_source, self.target_lang)
        _log_glossary_hits(translator, new_source, target_lang)
        try:
            zh, translate_ms = translator.translate(new_source, target_lang=target_lang)
        except Exception as exc:
            counts["errors"] += 1
            return self._error_event(event, new_source, str(exc))

        if _is_explanation(zh):
            counts["errors"] += 1
            return self._error_event(event, new_source, f"bad_full_output: {zh[:40]}")

        # 兜底 prompt leak 检测（_do_delta 也加了同样逻辑）。translator
        # 内部已剥 delta_zh 开头，但 merged_zh 整段里仍可能含 prompt
        # 关键字——drop final 避免把翻译器 prompt 当字幕显示。
        cleaned_zh, leak_hit = _strip_prompt_leak(zh)
        if leak_hit:
            with self.out_lock:
                key = _source_key(event)
                print(
                    f"\r\033[K[warn] drop leak final (full) @ {key} "
                    f"src={new_source[:50]!r}",
                    flush=True,
                )
            self.counts["leak_drops"] = self.counts.get("leak_drops", 0) + 1
            return None
        zh = cleaned_zh

        self.last_source_text = new_source
        self.last_translated_text = zh
        self.last_source_key = _source_key(event)

        if fallback_reason:
            counts["fallbacks"] += 1
            event_type = "translation_reset"
        else:
            event_type = "translation_final"

        counts["translated"] += 1
        return {
            "event_type": event_type,
            "source_key": _source_key(event),
            "source_update_mode": mode,
            "source_text": new_source,
            "delta_source_text": new_source,
            "translated_delta_text": zh,
            "translated_full_text": zh,
            "translate_ms": round(translate_ms, 1),
            "shared_prefix_len": 0,
            "glossary_hits": [],
            "retried": False,
            "fallback_reason": fallback_reason,
        }

    def _error_event(self, event, source_text, error_msg):
        return {
            "event_type": "translation_error",
            "source_key": _source_key(event),
            "source_seg_start": event.get("seg_start"),
            "source_seg_end": event.get("seg_end"),
            "source_text": source_text,
            "error": error_msg,
            "retriable": True,
        }


# ── 异步翻译工作线程 ──────────────────────────────────────────────────────────

class TranslateWorker:
    """后台翻译线程：partial 模式下异步处理翻译任务。"""

    def __init__(self, translator, trans_state, partial_cache,
                 f_trans, f_zh, f_bi, out_lock, counts, is_partial_mode):
        self.translator = translator
        self.trans_state = trans_state
        self.partial_cache = partial_cache
        self.f_trans = f_trans
        self.f_zh = f_zh
        self.f_bi = f_bi
        self.out_lock = out_lock
        self.counts = counts
        self.is_partial_mode = is_partial_mode
        self._queue: Queue = Queue()
        self._auto_promote_timer: threading.Timer | None = None
        self._last_partial_key: str | None = None
        self._last_partial_zh: str | None = None
        self._last_partial_src: str | None = None
        self._last_partial_event: dict | None = None
        # 增量翻译状态：每个 key 追踪上一次的源文本和翻译
        self._partial_state: dict[str, tuple[str, str]] = {}  # key → (last_src, last_zh)
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        self._thread.start()

    def stop(self):
        self._queue.put(None)
        self._thread.join(timeout=120)
        if self._thread.is_alive():
            print("[warn] worker thread did not exit within 120s, closing files anyway", flush=True)

    def dispatch_partial(self, event, source_text, key):
        """异步处理 partial 事件（仅翻译 + 显示，不写文件）。"""
        self._queue.put(("partial", event, source_text, key))

    def dispatch_final(self, event, source_text, key):
        """异步处理 final 事件（翻译 + 显示 + 写文件）。"""
        self._queue.put(("final", event, source_text, key))

    def _run(self):
        processed = 0
        while True:
            try:
                item = self._queue.get(timeout=0.5)
            except Empty:
                continue
            if item is None:
                break
            mode, event, source_text, key = item
            try:
                if mode == "partial":
                    self._do_partial(event, source_text, key)
                else:
                    out_event = self._do_final(event, source_text, key)
                    self._write_final_output(out_event, event)
                processed += 1
            except Exception as exc:
                print(f"\n[warn] worker error ({processed} done): {exc}", flush=True)
                import traceback; traceback.print_exc()
        print(f"[translate] worker exiting after {processed} items", flush=True)

    def _do_partial(self, event, source_text, key):
        """Partial: 增量翻译 — 只翻译新增部分，追加到已有翻译。

        走流式路径：每个翻译 token 都立刻写一个 translation_partial
        事件，macui 端按 token 浮现。整段 partial 同步保留，因为
        legacy macui 端只看 cumulative。
        """
        if self.partial_cache.get(key, (None,))[0] == source_text:
            return

        t = _format_time(event.get("audio_start_sec", 0))
        target_lang = resolve_target_lang(source_text, self.trans_state.target_lang)

        # 获取上一次的状态
        last_src, last_zh = self._partial_state.get(key, ("", ""))

        # Track in-flight streaming state so the per-token callback
        # can update partial_state on every chunk and the legacy
        # 'full' value of any single token is always the cumulative
        # translation (last_zh + this run's full).  Closed over by
        # the streaming on_token callback below.
        cumulative_zh = [last_zh]  # mutable box so on_token can mutate

        def _on_token_streaming(piece: str, full: str) -> None:
            # piece: 新增的 token；full: 本次翻译累计中文全文
            # 我们要把 "last_zh + full" 写到 JSONL 让 macui 看到
            # 完整的"已经看到的源文 → 翻译"映射。
            #
            # 同样检查 prompt leak：模型有时把 "只输出翻译结果..." 这种
            # system prompt 当源文翻译出来。partial 也走 leak 检测，
            # 命中就 drop partial（不写 JSONL），避免 macui 看到一堆
            # "只输出翻译结果" 的 draft。
            cumulative_zh = last_zh + full
            _, leak_hit = _strip_prompt_leak(cumulative_zh)
            if leak_hit:
                return
            self._partial_state[key] = (source_text, cumulative_zh)
            self.partial_cache[key] = (source_text, cumulative_zh)
            ev = {
                "event_type": "translation_partial",
                "source_key": key,
                "source_text": source_text,
                "translated_full_text": last_zh + full,
                "is_streaming_token": True,
                "streaming_piece": piece,
            }
            with self.out_lock:
                self.f_trans.write(json.dumps(ev, ensure_ascii=False) + "\n")
                self.f_trans.flush()

        if last_src and source_text.startswith(last_src):
            # 纯追加：新文本以旧文本为前缀，只翻译新增部分
            delta_src = source_text[len(last_src):]
            if not delta_src.strip():
                return
            try:
                _log_glossary_hits(self.translator, delta_src, target_lang)
                full_zh, ms, _meta = self.translator.translate_delta_streaming(
                    delta_src,
                    prev_source_tail=last_src[-40:],
                    prev_target_tail=last_zh[-20:],
                    on_token=_on_token_streaming,
                    target_lang=target_lang,
                )
            except Exception as exc:
                print(f"\n[partial] delta 翻译失败: {exc}", flush=True)
                # H10 修:发空 partial 事件,让 macui 清掉旧 draft ——
                # 否则流式推到一半的 partial 永远留在 UI,用户看到死文本。
                self._write_failed_partial(key, source_text)
                return
            if _is_explanation(full_zh):
                return
            # 追加到已有翻译
            final_zh = last_zh + full_zh
        else:
            # 源文本变化较大，全量翻译（少见）—— 也走流式
            try:
                _log_glossary_hits(self.translator, source_text, target_lang)
                full_zh, ms = self.translator.translate_streaming(
                    source_text,
                    on_token=_on_token_streaming,
                    target_lang=target_lang,
                )
            except Exception as exc:
                print(f"\n[partial] 全量翻译失败: {exc}", flush=True)
                # 同上,失败时给 UI 发空 partial 清掉旧 draft。
                self._write_failed_partial(key, source_text)
                return
            if _is_explanation(full_zh):
                return
            final_zh = full_zh

        # 关键：流式过程中已经写过 N 个 token 事件了（每个 token
        # 一次 translation_partial），不要在 _do_partial 末尾再
        # 写一次 cumulative 整段 — 那样会盖掉最后一个流式事件。
        # _do_final 看到 streaming token 之后会用最终 cumulative
        # 写 final 事件。cumulative_zh 已经在 _on_token_streaming
        # 末尾设过 last_zh + full 等于 final_zh 的"完整版"了。

        # 但要 stdout 显示最新状态
        with self.out_lock:
            sys.stdout.write(f"\r\033[K[partial][{t}] {final_zh}")
            sys.stdout.flush()

    def _do_final(self, event, source_text, key):
        """Final: 永远全量重译，不信任 partial_cache。

        设计原则（2026-06-28 修复）：partial 是草稿（实时流式显示用,可以错）,
        final 是正式字幕（必须正确）。Partial 用 prev_source_tail(40字) +
        prev_target_tail(20字) 小窗口增量翻,LLM 上下文不足会幻觉。
        Final 时拿完整 source 重译,partial 错了就覆盖。

        兜底: 全量重译失败时,如果 partial_cache 还在,退回用 partial (它错了
        也比没字幕强)。这个 fallback 用 fallback_reason 标记方便调试。
        """
        # 1. 取出 partial_cache (即使不用也清掉,避免下次 final 还命中)
        cached_entry = self.partial_cache.pop(key, None)
        had_cached_partial = cached_entry is not None
        # cached_entry 格式: (cached_src, cached_zh) — 但 _partial_state 里
        # 才是最新的 last_src/last_zh(partial 一直更新到最后一刻)。
        # _partial_state 在 partial 期间被 _on_token_streaming 持续刷新,
        # 比 partial_cache 更新。用它做兜底匹配。
        last_src, last_zh = self._partial_state.get(key, ("", ""))

        # 2. 全量重译 source_text
        target_lang = resolve_target_lang(source_text, self.trans_state.target_lang)
        _log_glossary_hits(self.translator, source_text, target_lang)
        fallback_reason = ""
        zh = ""
        translate_ms = 0.0

        try:
            zh, translate_ms = self.translator.translate(
                source_text, target_lang=target_lang
            )
        except Exception as exc:
            # 全量翻译失败 → 兜底用 partial 累积 (如果 source 一致)
            self.counts["errors"] += 1
            if last_src == source_text and last_zh:
                zh = last_zh
                fallback_reason = f"full_translate_failed_use_partial: {exc}"
                self.counts["fallbacks"] += 1
                print(
                    f"\r\033[K[warn] full translate failed @ {key}, "
                    f"using partial fallback: {exc}",
                    flush=True,
                )
            else:
                return self._error_event(event, source_text, str(exc))

        # 3. prompt leak 兜底: 全量翻译内部已剥 _strip_prompt_leak,
        # 但翻译器偶尔漏过 — 再 check 一次整段,命中就 drop final。
        cleaned_zh, leak_hit = _strip_prompt_leak(zh)
        if leak_hit:
            with self.out_lock:
                print(
                    f"\r\033[K[warn] drop leak final (full) @ {key} "
                    f"src={source_text[:50]!r}",
                    flush=True,
                )
            self.counts["leak_drops"] = self.counts.get("leak_drops", 0) + 1
            return None
        zh = cleaned_zh

        # 4. 决定 source_update_mode — 调试用,UI 不依赖它。
        # - full_translate: 没有 partial (first-final 或 partial 被丢)
        # - full_translate_corrected_partial: 有 partial 且本次覆盖了它
        if had_cached_partial and not fallback_reason:
            mode = "full_translate_corrected_partial"
        elif fallback_reason:
            mode = "full_translate_failed_use_partial"
        else:
            mode = "full_translate"

        # 5. 更新 trans_state 缓冲 — 下一个 final 的 delta 计算需要
        self.trans_state.last_source_text = source_text
        self.trans_state.last_translated_text = zh
        self.trans_state.last_source_key = key
        # 同步清掉 _partial_state 这个 key — final 已落地,partial 状态归零
        self._partial_state.pop(key, None)
        self.counts["translated"] += 1

        out_event = {
            "event_type": "translation_final",
            "source_key": key,
            "source_update_mode": mode,
            "source_text": source_text,
            # delta_source_text / translated_delta_text 字段保留以兼容旧 UI,
            # 但语义上是"本次重译覆盖了之前所有 partial",而非 delta。
            "delta_source_text": source_text,
            "translated_delta_text": zh,
            "translated_full_text": zh,
            "translate_ms": round(translate_ms, 1),
            "shared_prefix_len": 0,
            "glossary_hits": [],
            "retried": False,
            "fallback_reason": fallback_reason,
        }
        return out_event

    def _write_failed_partial(self, key: str, source_text: str) -> None:
        """翻译失败时给 macui 发一个空 partial 事件,清掉 UI 上的旧 draft。
        H10 修:之前失败路径只 print,流式推到一半的 partial 永远留在 UI。
        """
        ev = {
            "event_type": "translation_partial",
            "source_key": key,
            "source_text": source_text,
            "translated_full_text": "",  # 空串 → macui 清掉 draft
            "is_streaming_token": False,
        }
        try:
            with self.out_lock:
                self.f_trans.write(json.dumps(ev, ensure_ascii=False) + "\n")
                self.f_trans.flush()
        except Exception as exc:
            # 写盘失败 (磁盘满 / out_dir 不可写),不要让 _do_partial 抛错
            # 把 already-excepting 路径给覆盖了 — print 一下即可。
            print(f"[partial] 写失败事件失败: {exc}", flush=True)

    def _write_final_output(self, out_event, event):
        """把 _do_final 返回的 out_event 写到所有 JSONL 文件 + stdout。
        抽出公共写盘逻辑,让 _do_final 内部不再关心 IO。
        """
        if out_event is None:
            return

        if out_event.get("event_type") == "translation_error":
            with self.out_lock:
                print(f"\n[warn] {out_event.get('error', '')[:60]}", flush=True)
            return

        zh_full = out_event["translated_full_text"]
        t_start = _format_time(event.get("audio_start_sec", 0))
        t_end = _format_time(event.get("audio_end_sec", 0))
        ms = out_event.get("translate_ms", 0)
        mode = out_event.get("source_update_mode", "")

        with self.out_lock:
            if self.is_partial_mode:
                sys.stdout.write("\n")
            label = f"[{mode}]" if mode else ""
            print(f"[final]{label} [{t_start}-{t_end}] {zh_full}  ({ms:.0f}ms)", flush=True)

            self.f_trans.write(json.dumps(out_event, ensure_ascii=False) + "\n")
            self.f_trans.flush()
            self.f_zh.write(zh_full + "\n")
            self.f_zh.flush()
            self.f_bi.write(_bilingual_line(event, zh_full))
            self.f_bi.flush()


# ── 状态管理 ────────────────────────────────────────────────────────────────────

def _load_state(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {"byte_offset": 0}


def _save_state(path: str, state: dict):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False)
    os.replace(tmp, path)


# ── 主循环 ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="实时翻译消费者（增量翻译）")
    parser.add_argument("--events", required=True, help="whicc.py 的 events.jsonl 路径")
    parser.add_argument("--out-dir", required=True, help="翻译输出目录")
    # --model-id 默认值是 ""
    # 没在 UI 配 translation_model 时,不该给 vLLM 塞个默认模型 ID
    # (不同 vLLM 部署挂的模型不一样,塞错会导致 404/加载错模型)。
    # 下面 main() 里有"lang_config > CLI > model_id"优先级;这里空串
    # 表示"完全没默认值",CLI 显式 --model-id 才用。
    parser.add_argument("--model-id", default="",
                        help="默认翻译模型 ID (空=无默认值,推荐用"
                             " lang_config.json:translation_model 或"
                             " --translation-model)。")
    parser.add_argument("--translation-model", default="",
                        help="远端翻译节点(vLLM/LM Studio)的模型名称，发到 /v1/chat/completions "
                             "请求体的 model 字段。空 = 用 --model-id。也可由 lang_config.json 的"
                             " translation_model 键覆盖。")
    parser.add_argument("--vllm-url", default="",
                        help="远端翻译节点 URL。空 = 不在 CLI 设默认值,只走"
                             " lang_config.json 配的 translation_url /"
                             " translation_fallback_url。")
    parser.add_argument("--vllm-fallback-url", default="",
                        help="远端翻译回退 URL (本机 LM Studio 等)。"
                             "空 = 同上,只走 lang_config.json。")
    parser.add_argument("--glossary", default=os.path.join(os.path.dirname(__file__), "glossary.json"))
    parser.add_argument("--temperature", type=float, default=0.7)
    parser.add_argument("--top-p", type=float, default=0.6)
    parser.add_argument("--top-k", type=int, default=5)
    parser.add_argument("--repetition-penalty", type=float, default=1.02)
    parser.add_argument("--poll-interval", type=float, default=0.05,
                        help="轮询间隔（秒，默认 0.05）")
    parser.add_argument("--max-new-tokens", type=int, default=80,
                        help="最大生成 token 数（默认 80）")
    parser.add_argument("--once", action="store_true", help="只处理已有事件，不持续 tail")
    parser.add_argument("--context-size", type=int, default=0,
                        help="传给翻译器的上下文条数（0=不传）")
    parser.add_argument("--mode", default="final", choices=["final", "partial"],
                        help="final=只翻 final 事件；partial=翻 partial 事件（同声传译模式）")
    parser.add_argument("--target-lang", default="auto",
                        help="目标语言（auto=自动检测，或语言名如 'Japanese', 'German', 'zh-cn'）")
    parser.add_argument("--force-enable", action="store_true",
                        help="绕过 lang_config.json 的 translation_enabled 检查 (用于 .app 打包模式)")
    args = parser.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)

    trans_events_path = os.path.join(args.out_dir, "translation_events.jsonl")
    zh_txt_path = os.path.join(args.out_dir, "translation_zh.txt")
    bilingual_path = os.path.join(args.out_dir, "translation_bilingual.txt")
    state_path = os.path.join(args.out_dir, "translation_state.json")

    # 从 lang_config.json 读取 translation_url（UI 配置优先）
    # 注意：lang_config.json 是 macui 设置界面和 Python 后端**共享**的文件。
    # macui 可能在其中存 scene_text、hermes_host 等其他键，Python 端不能
    # 整体覆盖（dict 全量 json.dump）—— 那会把其他键全删掉。
    # 标准做法：只读自己关心的键，写回时用 read-modify-write。
    lang_cfg = {}
    try:
        with open(os.path.join(args.out_dir, "lang_config.json"), "r") as f:
            lang_cfg = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    configured_url = (lang_cfg.get("translation_url") or "").strip()
    configured_fb = (lang_cfg.get("translation_fallback_url") or "").strip()
    # 优先级: lang_config.json (用户 UI 配) > CLI 参数
    # 现在 CLI 默认值是 "" 空串,
    # 用户没在 UI 配翻译节点 → vllm_url = "", 下面 candidates 是空,
    # translate_stream 干净退出 + 提示用户去 macui 配翻译。
    vllm_url = configured_url if configured_url else (args.vllm_url or "").strip()
    # 不要把 CLI 默认值写回 lang_config.json — 那是用户私有的局域网地址,
    # 写回去会让 Ethan 之类朋友看到你家的 vllm URL 当成默认。
    if not configured_url and vllm_url:
        # 用户通过 CLI 显式传了 --vllm-url, 把这个写回 lang_config.json
        # 默认值(我们在 BackendLauncher 不传了,这里要确保)。
        lang_cfg["translation_url"] = vllm_url
        try:
            _atomic_write_json(os.path.join(args.out_dir, "lang_config.json"), lang_cfg)
        except OSError:
            pass
    if configured_url:
        if not vllm_url.startswith("http"):
            vllm_url = f"http://{vllm_url}"
        print(f"[translate] 使用配置的翻译节点: {vllm_url}", flush=True)
    if configured_fb:
        if not configured_fb.startswith("http"):
            configured_fb = f"http://{configured_fb}"
        print(f"[translate] 使用配置的翻译回退: {configured_fb}", flush=True)

    # 翻译节点总开关:lang_config.json 的 translation_enabled 决定是否
    # 真的连远端翻译节点。默认 False — 即使填了 URL 也不会自动启用,
    # 用户必须显式开。关 = 翻译不可用 (不再回退到本地,本地 transformers
    # 后端已删除)。改完需重启 translate_stream 生效。
    translation_enabled = bool(lang_cfg.get("translation_enabled", False))
    if not translation_enabled and not args.force_enable:
        print(f"[translate] translation_enabled=False,翻译未启用,退出", flush=True)
        print(f"[translate] 请在 macui 设置 → 服务配置 → 启用远端翻译,"
              f"并配置翻译节点地址", flush=True)
        sys.exit(1)
    if args.force_enable and not translation_enabled:
        print(f"[translate] --force-enable 覆盖 lang_config.json 的 enabled=False,"
              f"继续启动 (打包模式 .app 行为)", flush=True)
    print(f"[translate] translation_enabled=True,允许走远端翻译", flush=True)

    # 远端模型名称：lang_config.json 里的 translation_model 优先，
    # 否则用 --translation-model CLI，否则回退到 --model-id 默认值。
    # 这样 UI 配置能覆盖 CLI 默认，CLI 又能覆盖硬编码值。
    configured_model = (lang_cfg.get("translation_model") or "").strip()
    cli_model = (args.translation_model or "").strip()
    if configured_model:
        model_id = configured_model
        print(f"[translate] 使用配置的远端模型: {model_id}", flush=True)
    elif cli_model:
        model_id = cli_model
        print(f"[translate] 使用 CLI 指定的远端模型: {model_id}", flush=True)
    else:
        model_id = args.model_id
        if model_id:
            print(f"[translate] 使用 --model-id 默认模型: {model_id}", flush=True)
        else:
            # 完全没配置模型名 — 不给 vLLM 塞个写死的 Hy-MT2 (用户 vLLM 上可能
            # 挂着完全不同的模型,塞错会导致 404/load 错模型)。发请求时 model
            # 字段留空,让 vLLM 服务端用自己加载的默认模型。
            print(f"[translate] 未配置 translation_model / --translation-model / "
                  f"--model-id,将让 vLLM 服务端自行选择默认模型", flush=True)

    # Fallback 用的模型名: lang_config.json:translation_fallback_model
    # 未配置 → 跟主 URL 共用 model_id (向后兼容,旧用户零迁移)
    # 如果主 model_id 也是空 (用户没在 UI/CLI 配),fb 也保持空,
    # 由 vLLM 服务端自己选默认模型。
    configured_fb_model = (lang_cfg.get("translation_fallback_model") or "").strip()
    fb_model_id = configured_fb_model if configured_fb_model else model_id
    if configured_fb_model:
        print(f"[translate] 使用配置的 fallback 模型: {fb_model_id}", flush=True)
    elif model_id:
        print(f"[translate] fallback 模型未配置,沿用主模型: {fb_model_id}", flush=True)
    else:
        print(f"[translate] fallback 模型未配置,主模型也未配置,fb 留空", flush=True)

    # 翻译节点 fallback 链（按优先级，VLLMBackend 内部按序探活挑首个健康）:
    # 1. lang_config.json:translation_url          (UI 主 URL)
    # 2. lang_config.json:translation_fallback_url (UI fallback URL)
    # 3. --vllm-url CLI 参数 (外部脚本可能传,BackendLauncher 不传)
    # 4. --vllm-fallback-url CLI 参数 (同上)
    # CLI 的 --vllm-url / --vllm-fallback-url 默认值都是 ""
    # 只有任一来源配出 URL 才会进 candidates;都空就下面 if not candidates 退出。
    candidates: list[str] = []
    if vllm_url:
        candidates.append(vllm_url)
    if configured_fb and configured_fb not in candidates:
        candidates.append(configured_fb)
    cli_fb = (args.vllm_fallback_url or "").strip()
    if cli_fb and cli_fb not in candidates:
        candidates.append(cli_fb)

    if not candidates:
        print(f"[translate] 未配置任何翻译节点 URL (translation_url / "
              f"translation_fallback_url / --vllm-url / --vllm-fallback-url),退出", flush=True)
        sys.exit(1)

    # per-URL model_map: fallback URL 用 fb_model_id (可能跟主 URL 不同)
    # 主 URL 用 model_id (fallback map 里没写)。backend 内部 _resolve_ipv4
    # 标准化 key,所以上层传原始 URL string 即可。
    model_map: dict[str, str] = {}
    if configured_fb and configured_fb_model:
        model_map[configured_fb] = fb_model_id
    if cli_fb and cli_fb != configured_fb and configured_fb_model:
        # CLI fallback (外部脚本可能传) 用配置的 fb model — 也算"本机"
        model_map[cli_fb] = fb_model_id

    # per-URL API key: 主/备节点各自的鉴权 key(macui 设置页配,可空)。
    # 非空时该 URL 的所有请求(探活 + 翻译)带 Authorization: Bearer 头。
    api_key_map: dict[str, str] = {}
    main_api_key = (lang_cfg.get("translation_api_key") or "").strip()
    fb_api_key = (lang_cfg.get("translation_fallback_api_key") or "").strip()
    if vllm_url and main_api_key:
        api_key_map[vllm_url] = main_api_key
    if configured_fb and fb_api_key:
        api_key_map[configured_fb] = fb_api_key
    if cli_fb and cli_fb != configured_fb and fb_api_key:
        api_key_map[cli_fb] = fb_api_key
    if api_key_map:
        print(f"[translate] 已配置 API key ({len(api_key_map)} 个节点)", flush=True)

    # 请求端点: auto(默认,404 自适应) / chat(/v1/chat/completions) /
    # responses(/v1/responses — GPT 系列流式端点,一些站点只提供它)
    endpoint = (lang_cfg.get("translation_endpoint") or "auto").strip().lower()
    if endpoint not in ("auto", "chat", "responses"):
        print(f"[translate] 未知 translation_endpoint '{endpoint}',回退 auto", flush=True)
        endpoint = "auto"
    print(f"[translate] 翻译请求端点: {endpoint}", flush=True)

    # __init__ 内部就做健康探活,失败抛异常 — 建一次直接用,失败就退出
    # (比让进程空转报错更友好;早期版本先建一个丢弃的实例探活,再建正式的,
    # 启动时白跑两次 GET /v1/models,已合并)。
    try:
        translator = HyMT2Translator(
            model_id=model_id,
            vllm_url=candidates,
            model_map=model_map,
            glossary_path=args.glossary,
            temperature=args.temperature,
            top_p=args.top_p,
            top_k=args.top_k,
            repetition_penalty=args.repetition_penalty,
            max_new_tokens=args.max_new_tokens,
            api_key_map=api_key_map,
            endpoint=endpoint,
        )
        print(f"[translate] 已连接翻译服务,候选: {candidates}", flush=True)
    except Exception as e:
        print(f"[translate] 所有候选翻译节点都不可达: {e}", flush=True)
        sys.exit(1)

    state = _load_state(state_path)
    byte_offset = state.get("byte_offset", 0)
    pending_partial_line = state.get("pending_partial_line", "")

    f_trans = open(trans_events_path, "a", encoding="utf-8")
    f_zh = open(zh_txt_path, "a", encoding="utf-8")
    f_bi = open(bilingual_path, "a", encoding="utf-8")

    counts = {"translated": 0, "errors": 0, "deltas": 0, "fallbacks": 0}
    is_partial_mode = args.mode == "partial"
    out_lock = threading.Lock()

    # 解析目标语言
    initial_target_lang = None  # None = auto
    if args.target_lang.lower() != "auto":
        try:
            tl = normalize_target_language(args.target_lang)
            initial_target_lang = tl.prompt_name
            print(f"[translate] 目标语言: {tl.prompt_name} ({tl.code})", flush=True)
        except ValueError as e:
            print(f"[translate] 未知语言 '{args.target_lang}'，使用自动模式: {e}", flush=True)
    else:
        print(f"[translate] 目标语言: 自动（中文→英文，其他→中文）", flush=True)

    # lang_config.json 热重载路径
    lang_config_path = os.path.join(args.out_dir, "lang_config.json")

    trans_state = TranslationState(target_lang=initial_target_lang)
    partial_cache: dict[str, tuple[str, str]] = {}

    worker = None
    if is_partial_mode:
        worker = TranslateWorker(
            translator, trans_state, partial_cache,
            f_trans, f_zh, f_bi, out_lock, counts, is_partial_mode,
        )
        worker.start()
        print("[translate] 同声传译模式（增量翻译 + 异步线程）", flush=True)

    def _flush_state():
        # 注: 早期版本还持久化 processed_keys/failed_keys 两个集合,但去重
        # 逻辑已改走 partial_cache,它们只增不读、每次全量序列化 — 长会话
        # 内存与磁盘 IO 无限上涨,已删除。旧 state 文件里的多余键被忽略。
        _save_state(state_path, {
            "byte_offset": byte_offset,
            "pending_partial_line": pending_partial_line,
        })

    def _write_output(event, out_event):
        """写翻译结果到文件和终端（final 模式同步调用）。"""
        if out_event is None or out_event.get("event_type") == "translation_error":
            return
        zh_full = out_event["translated_full_text"]
        t_start = _format_time(event.get("audio_start_sec", 0))
        t_end = _format_time(event.get("audio_end_sec", 0))
        ms = out_event.get("translate_ms", 0)
        mode = out_event.get("source_update_mode", "")
        label = f"[{mode}]" if mode else ""

        with out_lock:
            print(f"[final]{label} [{t_start}-{t_end}] {zh_full}  ({ms:.0f}ms)", flush=True)
            f_trans.write(json.dumps(out_event, ensure_ascii=False) + "\n")
            f_trans.flush()
            f_zh.write(zh_full + "\n")
            f_zh.flush()
            f_bi.write(_bilingual_line(event, zh_full))
            f_bi.flush()

    print(f"[translate] 开始消费 {args.events} (offset={byte_offset})", flush=True)

    # ── 词库热加载 ──
    _glossary_path = args.glossary
    try:
        _last_glossary_mtime = os.path.getmtime(_glossary_path)
    except OSError:
        _last_glossary_mtime = 0.0
    _glossary_check_counter = 0

    def _try_reload_glossary():
        nonlocal _last_glossary_mtime, _glossary_check_counter
        _glossary_check_counter += 1
        if _glossary_check_counter % 200 != 0:  # 每 200 次循环检查一次
            return
        try:
            mtime = os.path.getmtime(_glossary_path)
        except OSError:
            return
        if mtime <= _last_glossary_mtime:
            return
        try:
            with open(_glossary_path, "r", encoding="utf-8") as gf:
                new_glossary = json.load(gf)
            _base_glossary = new_glossary
            # 合并临时事件词库
            _merge_event_glossary()
            _last_glossary_mtime = mtime
            total = sum(len(v) for v in translator.glossary.values())
            print(f"[translate] 词库热加载完成（{total} 条）", flush=True)
        except Exception as exc:
            print(f"[translate] 词库加载失败: {exc}", flush=True)

    # ── 目标语言热重载 ──
    _last_lang_config_mtime = 0.0
    _lang_check_counter = 0

    # ── 临时事件词库/场景热重载 ──
    event_glossary_path = os.path.join(args.out_dir, "event_glossary.json")
    event_scene_path = os.path.join(args.out_dir, "event_scene.json")
    _last_event_glossary_mtime = 0.0
    _event_glossary_check_counter = 0
    _last_event_scene_mtime = 0.0
    _event_scene_check_counter = 0
    _base_glossary = dict(translator.glossary)  # 保存永久词库快照
    _event_active = False  # 当前是否有活跃事件
    _lang_check_counter = 0

    def _try_reload_lang():
        nonlocal _last_lang_config_mtime, _lang_check_counter
        _lang_check_counter += 1
        if _lang_check_counter % 200 != 0:
            return
        try:
            mtime = os.path.getmtime(lang_config_path)
        except OSError:
            return
        if mtime <= _last_lang_config_mtime:
            return
        try:
            with open(lang_config_path, "r", encoding="utf-8") as lf:
                cfg = json.load(lf)
            new_lang = cfg.get("target_lang", "auto")
            if new_lang.lower() == "auto":
                trans_state.target_lang = None
                print(f"[translate] 目标语言切换: 自动", flush=True)
            else:
                tl = normalize_target_language(new_lang)
                trans_state.target_lang = tl.prompt_name
                print(f"[translate] 目标语言切换: {tl.prompt_name} ({tl.code})", flush=True)
            _last_lang_config_mtime = mtime
        except Exception as exc:
            print(f"[translate] 语言配置加载失败: {exc}", flush=True)

    # ── 临时事件词库合并 ──
    def _merge_event_glossary():
        """将 event_glossary 合并到 _base_glossary 上，不修改 _base_glossary。"""
        event_gloss = {}
        try:
            with open(event_glossary_path, "r", encoding="utf-8") as ef:
                event_gloss = json.load(ef)
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        merged = dict(_base_glossary)
        merged["en2zh"] = dict(merged.get("en2zh", {}))
        merged["zh2en"] = dict(merged.get("zh2en", {}))
        for en, value in event_gloss.get("en2zh", {}).items():
            if isinstance(value, dict):
                merged["en2zh"][en] = value.get("translation", en)
            else:
                merged["en2zh"][en] = value
        for zh, value in event_gloss.get("zh2en", {}).items():
            if isinstance(value, dict):
                merged["zh2en"][zh] = value.get("translation", zh)
            else:
                merged["zh2en"][zh] = value
        translator.glossary = merged

    # ── 临时事件词库热重载 ──
    def _try_reload_event_glossary():
        nonlocal _last_event_glossary_mtime, _event_glossary_check_counter
        _event_glossary_check_counter += 1
        if _event_glossary_check_counter % 200 != 0:
            return
        try:
            mtime = os.path.getmtime(event_glossary_path)
        except OSError:
            return
        if mtime <= _last_event_glossary_mtime:
            return
        _last_event_glossary_mtime = mtime
        _merge_event_glossary()
        total = sum(len(v) for v in translator.glossary.values())
        event_en = len(translator.glossary.get("en2zh", {})) - len(_base_glossary.get("en2zh", {}))
        event_zh = len(translator.glossary.get("zh2en", {})) - len(_base_glossary.get("zh2en", {}))
        if event_en > 0 or event_zh > 0:
            print(f"[event] 临时词库已加载 (en2zh+{event_en}, zh2en+{event_zh}, 总{total})", flush=True)

    # ── 临时事件场景热重载 ──
    def _try_reload_event_scene():
        nonlocal _last_event_scene_mtime, _event_scene_check_counter, _event_active
        _event_scene_check_counter += 1
        if _event_scene_check_counter % 200 != 0:
            return
        try:
            mtime = os.path.getmtime(event_scene_path)
        except OSError:
            return
        if mtime <= _last_event_scene_mtime:
            return
        _last_event_scene_mtime = mtime
        try:
            with open(event_scene_path, "r", encoding="utf-8") as sf:
                scene_data = json.load(sf)
        except (FileNotFoundError, json.JSONDecodeError):
            return

        status = scene_data.get("status", "")
        if status == "applied":
            scene_text = scene_data.get("temp_scene_text", "")
            event_name = scene_data.get("event_name", "")
            expires_at = scene_data.get("expires_at", "")
            # 检查 TTL 是否过期
            if expires_at:
                try:
                    exp = datetime.datetime.fromisoformat(expires_at)
                    if datetime.datetime.now() > exp:
                        # TTL 过期，清除事件，直接恢复 base glossary
                        print(f"[event] 事件 '{event_name}' TTL 过期，清除场景", flush=True)
                        _event_active = False
                        set_scene_context("")
                        translator.glossary = {"en2zh": dict(_base_glossary.get("en2zh", {})),
                                               "zh2en": dict(_base_glossary.get("zh2en", {}))}
                        return
                except ValueError:
                    pass
            _event_active = True
            set_scene_context(scene_text)
            print(f"[event] 场景已应用: {event_name} → {scene_text[:40]}...", flush=True)
        elif status == "idle":
            if _event_active:
                _event_active = False
                set_scene_context("")
                translator.glossary = {"en2zh": dict(_base_glossary.get("en2zh", {})),
                                       "zh2en": dict(_base_glossary.get("zh2en", {}))}
                print(f"[event] 事件已清除", flush=True)

    try:
        while True:
            _try_reload_glossary()
            _try_reload_lang()
            _try_reload_event_glossary()
            _try_reload_event_scene()
            try:
                fsize = os.path.getsize(args.events)
            except OSError:
                if args.once:
                    break
                time.sleep(args.poll_interval)
                continue

            if fsize < byte_offset:
                # 文件被截断/rotate/truncate — 之前累积的 offset 失效。
                # 重置到文件开头,避免永久卡死。
                print(f"[translate] events.jsonl was truncated/rotated "
                      f"(fsize={fsize} < byte_offset={byte_offset}), "
                      f"resetting offset", flush=True)
                byte_offset = 0
                # 也清空 saved state 里的旧 offset,持久层也跟上
                _flush_state()
            elif fsize == byte_offset:
                if args.once:
                    break
                time.sleep(args.poll_interval)
                continue

            with open(args.events, "rb") as ef:
                ef.seek(byte_offset)
                new_data = ef.read()
                new_byte_offset = ef.tell()

            chunk_text = pending_partial_line + new_data.decode("utf-8", errors="replace")
            raw_lines = chunk_text.splitlines(keepends=True)
            pending_partial_line = ""

            for raw_line in raw_lines:
                if not raw_line.endswith("\n"):
                    pending_partial_line = raw_line
                    break

                line = raw_line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue

                etype = event.get("event_type")

                # ── partial 事件（partial 模式，异步翻译 + 显示）──
                if is_partial_mode and etype == "partial":
                    key = _source_key(event)
                    source_text = event.get("text", "").strip()
                    if not source_text:
                        continue
                    if partial_cache.get(key, (None,))[0] == source_text:
                        continue
                    worker.dispatch_partial(event, source_text, key)
                    continue

                # ── final 事件 ──
                if etype != "final":
                    continue
                if not event.get("accepted", False):
                    continue

                key = _source_key(event)
                # 不用 processed_keys 去重 — ASR 可能对同一段发多个 final（修正）
                # partial_cache 已经处理了重复翻译的问题

                source_text = event.get("text", "").strip()
                if not source_text:
                    continue

                if is_partial_mode and worker is not None:
                    # 异步：dispatch 给 worker，worker 内部做 classify + translate
                    worker.dispatch_final(event, source_text, key)
                else:
                    # 同步：主线程做 classify + translate + write
                    update_info = trans_state.classify(source_text)
                    out_event = trans_state.translate_final(
                        translator, source_text, update_info, event, counts,
                    )
                    if out_event and out_event.get("event_type") == "translation_error":
                        with out_lock:
                            f_trans.write(json.dumps(out_event, ensure_ascii=False) + "\n")
                            f_trans.flush()
                        _flush_state()
                        continue
                    _write_output(event, out_event)

            byte_offset = new_byte_offset
            _flush_state()
            if args.once:
                break

    except KeyboardInterrupt:
        print("\n[translate] 退出。", flush=True)
    finally:
        if worker is not None:
            worker.stop()
        _flush_state()
        f_trans.close()
        f_zh.close()
        f_bi.close()
        print(f"[translate] 完成：{counts['translated']} 条翻译, "
              f"{counts['errors']} 条错误, "
              f"{counts['deltas']} 条增量, "
              f"{counts['fallbacks']} 次 fallback", flush=True)


if __name__ == "__main__":
    main()
