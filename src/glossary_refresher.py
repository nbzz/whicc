#!/usr/bin/env python3
"""
自学习术语优化器 v3：纯 NLP + web search，零硬编码。
1. jieba 分词 + 词频统计提取候选术语
2. Web search 查每个术语的英文翻译
3. LM Studio 做 fallback 翻译
4. 写入 glossary.json，translate_stream 热加载
"""
import json
import os
import re
import subprocess
import shlex
import time
import datetime
import urllib.request
import urllib.parse
import sys
import shutil
from collections import Counter

import jieba
import jieba.posseg as pseg

EVENTS_PATH = "/tmp/whicc-out/translation_events.jsonl"
GLOSSARY_PATH = os.path.join(os.path.dirname(__file__), "glossary.json")
META_PATH = os.path.join(os.path.dirname(__file__), "_glossary_meta.json")
CONTROL_PATH = os.path.join(os.path.dirname(__file__), "_glossary_control.json")
CHANGES_PATH = os.path.join(os.path.dirname(__file__), "_glossary_changes.jsonl")
# LM Studio fallback URL — 从 lang_config.json 读 (translation_fallback_url)。
# 局域网地址,别人电脑 glossary_refresher 在 Hermes 搜不到术语时调这里翻译会
# 连不上 → 静默失败 (整个术语被跳过)。现在从 lang_config.json 读,跟 macui
# 翻译 fallback URL 共用一个字段 — 用户配了 vLLM fallback URL 这边就用。
LM_STUDIO_URL = ""  # 启动时由 _load_lm_studio_url() 从 lang_config.json 读
LM_STUDIO_MODEL = "hy-mt2-1.8b"
# Hermes 是可选的,只在用户机器上装了 Hermes CLI 才有用。
# - HERMES_HOST: 用户的 Hermes 节点地址,默认 "" (未配置)。
#   从 lang_config.json 读,用户没配就空 → 跳过 Hermes 调用。
# - HERMES_INVOKE: 远端怎么调用 hermes CLI,由 _resolve_hermes_invoke() 探测。
#   不硬编码路径 (开发者机器绝对路径在别人电脑不可用)。
HERMES_HOST = ""
HERMES_INVOKE = ""  # 由 _resolve_hermes_invoke() 首次调用时探测并缓存


def _load_lm_studio_url() -> str:
    """从 /tmp/whicc-out/lang_config.json 读 translation_fallback_url。
    字段缺失或空时返回空字符串,lm_translate_single 会跳过调用。"""
    cfg_path = "/tmp/whicc-out/lang_config.json"
    try:
        if not os.path.exists(cfg_path):
            return ""
        with open(cfg_path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
        url = (cfg.get("translation_fallback_url") or "").strip()
        return url.rstrip("/") + "/v1/chat/completions" if url else ""
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return ""

POLL_INTERVAL = 90
SAMPLE_LINES = 80
MIN_NEW_TO_WRITE = 1
MAX_GLOSSARY_SIZE = 500
MIN_TERM_LEN = 2
MIN_TERM_FREQ = 2        # 至少出现 2 次才入库
MAX_CANDIDATES = 20       # 每轮最多翻译 20 个候选

# 过期策略（秒）
EXPIRE_HERMES = 7 * 86400    # Hermes 学的术语 7 天未命中过期
EXPIRE_WEB = 3 * 86400       # web search 的 3 天
EXPIRE_LM = 1 * 86400        # LM Studio 1.8B 的 1 天
CLEANUP_INTERVAL = 300       # 每 300 秒清理一次
_last_cleanup = 0.0

# 场景实体关键词（用于检测用户在看什么，触发主动 web search）
_SCENE_ENTITIES = {
    "体育": ["世界杯", "欧冠", "联赛", "比赛", "进球", "教练", "裁判"],
    "球队": ["葡萄牙", "巴西", "阿根廷", "法国", "德国", "西班牙", "英格兰",
             "曼联", "巴萨", "皇马", "拜仁", "切尔西", "曼城", "利物浦",
             "尤文", "国米", "巴黎", "阿森纳", "多特蒙德"],
    "财经": ["股票", "基金", "利率", "美联储", "GDP", "通胀", "债券"],
    "科技": ["AI", "模型", "训练", "算法", "芯片", "GPU", "大模型"],
}

# ── 停用词（仅用于过滤，非翻译规则）──
_STOPWORDS_ZH = set(
    "的了是在我你他她它们这那就也都还不没会能要让把被给对"
    "从到过着呢吗啊吧哦嗯呀嘛啦诶嘿哎嗨噢呃哇"
    "一二三四五六七八九十百千万亿"
    "个只把条张件块毛块钱块"
    "上下左右前后里外中间"
    "和与或但而因为所以如果虽然但是"
    "这个那个每个什么怎么为什么"
    "可以应该必须需要可能已经正在"
    "来去说看听说知道觉得认为"
    "好不好看大少老新长短快慢"
    "人年月日时分秒"
    "了的呢吗啊吧嘛就是都有还不"
    "什么这个那个怎么为什么可以"
    "特别真的然后其实所以因为"
)


def _is_cjk(text: str) -> bool:
    """文本是否含 CJK 字符。"""
    return any('一' <= c <= '鿿' for c in text)


def _now_with_tz() -> str:
    now = datetime.datetime.now()
    tz = time.strftime("%Z") or time.tzname[0]
    utc_offset = time.strftime("%z") or ""
    return f"{now.strftime('%Y-%m-%d %H:%M:%S')} {tz} (UTC{utc_offset})"


# ── 事件采样 ──

def load_events(n: int = SAMPLE_LINES) -> list[str]:
    try:
        with open(EVENTS_PATH, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except FileNotFoundError:
        return []
    sources = []
    for line in reversed(lines):
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        if e.get("event_type") == "translation_final":
            src = e.get("source_text", "").strip()
            if src:
                sources.append(src)
            if len(sources) >= n:
                break
    return list(reversed(sources))


# ── jieba 提取候选术语 ──

def extract_candidates(sources: list[str]) -> list[str]:
    """用 jieba 分词 + 词频 + 词性筛选候选术语。"""
    word_freq = Counter()
    combined = "\n".join(sources)

    # jieba 词性标注：nr=人名, ns=地名, nt=机构名, nz=其他专名, n=名词
    PROPER_NOUN_POS = {"nr", "ns", "nt", "nz", "n", "eng"}

    for word, pos in pseg.cut(combined):
        w = word.strip()
        if len(w) < MIN_TERM_LEN:
            continue
        if w in _STOPWORDS_ZH:
            continue
        # 纯数字/标点跳过
        if re.match(r'^[\d\s\.\,\;\:\!\?\-]+$', w):
            continue
        # 优先保留专有名词和名词，也保留高频词
        if pos in PROPER_NOUN_POS:
            word_freq[w] += 1
        elif word_freq[w] >= MIN_TERM_FREQ:
            word_freq[w] += 1

    # 按频率排序，过滤低频
    candidates = [
        word for word, freq in word_freq.most_common(MAX_CANDIDATES)
        if freq >= MIN_TERM_FREQ
    ]
    return candidates


# ── Web Search 翻译 ──

def web_translate(zh_term: str) -> str | None:
    """用 web search 查找中文术语的英文翻译。"""
    query = urllib.parse.quote(f"{zh_term} English translation")
    url = f"https://lite.duckduckgo.com/lite/?q={query}"
    try:
        req = urllib.request.Request(url, headers={
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
        })
        with urllib.request.urlopen(req, timeout=10) as resp:
            html = resp.read().decode("utf-8", errors="replace")
        return _extract_translation(html, zh_term)
    except Exception:
        return None


def _extract_translation(html: str, zh_term: str) -> str | None:
    """从搜索结果中提取英文翻译。"""
    # 模式1: "中文 (English)" 或 "中文（English）"
    m = re.search(
        rf'{re.escape(zh_term)}\s*[\(（]\s*([A-Z][a-zA-Z\s\.\-]+?)\s*[\)）]',
        html
    )
    if m:
        candidate = m.group(1).strip()
        if 2 <= len(candidate) <= 40:
            return candidate

    # 模式2: "English - 中文" (Wikipedia 风格)
    m = re.search(
        rf'([A-Z][a-zA-Z\s\.\-]+?)\s*[-–—]\s*{re.escape(zh_term)}',
        html
    )
    if m:
        candidate = m.group(1).strip()
        if 2 <= len(candidate) <= 40 and not candidate.lower().startswith("http"):
            return candidate

    return None


# ── LM Studio fallback 翻译（逐词翻译，非批量）──

def lm_translate_single(zh_term: str) -> str | None:
    """用 LM Studio 翻译单个中文术语。URL 从 lang_config.json 读
    (translation_fallback_url 字段,用户在 macui 设置里配的)。
    如果字段空,直接返回 None — 没配翻译 fallback 就跳过术语翻译,
    glossary_refresher 也不会 crash。"""
    url = _load_lm_studio_url()
    if not url:
        return None
    payload = json.dumps({
        "model": LM_STUDIO_MODEL,
        "messages": [
            {"role": "system", "content": "You are a translator. Translate the Chinese term to English. Output only the English translation, nothing else."},
            {"role": "user", "content": zh_term},
        ],
        "temperature": 0.1,
        "max_tokens": 30,
    }).encode("utf-8")
    try:
        req = urllib.request.Request(
            url,
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = json.loads(resp.read().decode("utf-8"))
        result = body["choices"][0]["message"]["content"].strip()
        # 清理：去掉引号、换行
        result = result.strip('"\'\n').split("\n")[0].strip()
        if 2 <= len(result) <= 40 and re.search(r'[a-zA-Z]', result):
            return result
    except Exception:
        pass
    return None


# ── 词库读写 ──

def load_glossary() -> dict:
    try:
        with open(GLOSSARY_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
        for key in ("zh2en", "en2zh", "_meta"):
            if key not in data:
                data[key] = {} if key != "_meta" else {}
        return data
    except (FileNotFoundError, json.JSONDecodeError):
        return {"en2zh": {}, "zh2en": {}, "_meta": {}}


def save_glossary(glossary: dict):
    with open(GLOSSARY_PATH, "w", encoding="utf-8") as f:
        json.dump(glossary, f, ensure_ascii=False, indent=2)
        f.write("\n")


def _now_ts() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S")


def _is_paused() -> bool:
    try:
        with open(CONTROL_PATH, "r", encoding="utf-8") as f:
            return json.load(f).get("paused", False)
    except (FileNotFoundError, json.JSONDecodeError):
        return False


def _log_changes(added: dict[str, tuple[str, str]], removed: list[str]):
    """写变更日志供 overlay 读取。added: {zh: (en, source)}, removed: [zh, ...]"""
    entry = {
        "ts": _now_ts(),
        "added": {zh: en for zh, (en, _) in added.items()},
        "removed": removed,
    }
    try:
        with open(CHANGES_PATH, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except Exception:
        pass


def cleanup_glossary(glossary: dict) -> list[str]:
    """清理过期和无效术语。返回删除的术语列表。"""
    now = time.time()
    meta = glossary.get("_meta", {})
    zh2en = glossary.get("zh2en", {})
    en2zh = glossary.get("en2zh", {})
    removed = []

    # 清理无效术语（zh 不含 CJK 或含拉丁字符的脏数据）
    for zh in list(zh2en.keys()):
        if not _is_cjk(zh) or re.search(r'[a-zA-Z]', zh):
            removed.append(zh)
    for en in list(en2zh.keys()):
        if _is_cjk(en) or not re.search(r'[a-zA-Z]', en):
            removed.append(en)

    for term, info in list(meta.items()):
        source = info.get("source", "lm")
        last_used_str = info.get("last_used", info.get("added", ""))
        hits = info.get("hits", 0)

        # 解析时间
        try:
            last_used_ts = time.mktime(time.strptime(last_used_str, "%Y-%m-%d %H:%M:%S"))
        except (ValueError, TypeError):
            last_used_ts = now

        age = now - last_used_ts
        expire = {EXPIRE_HERMES: EXPIRE_HERMES, "hermes": EXPIRE_HERMES,
                  "web": EXPIRE_WEB, "lm": EXPIRE_LM}.get(source, EXPIRE_LM)

        # 0 次命中的术语更快过期（减半）
        if hits == 0:
            expire //= 2

        if age > expire:
            removed.append(term)

    for term in removed:
        meta.pop(term, None)
        # 双向清理
        if term in zh2en:
            en = zh2en.pop(term)
            en2zh.pop(en, None)
        elif term in en2zh:
            zh = en2zh.pop(term)
            zh2en.pop(zh, None)

    glossary["_meta"] = meta
    return removed


def save_meta(candidates: int, translated: int, added: int, method: str, scene: str = ""):
    meta = {
        "last_refresh": time.strftime("%Y-%m-%d %H:%M:%S"),
        "scene": scene,
        "candidates": candidates,
        "translated": translated,
        "terms_added": added,
        "method": method,
    }
    with open(META_PATH, "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)
        f.write("\n")


# ── 场景检测 + LM Studio Agent 术语获取 ──

def detect_scene(sources: list[str]) -> tuple[str, list[str]]:
    """从转录文本中检测场景，返回 (场景描述, 关键实体列表)。"""
    combined = " ".join(sources[-40:])
    found_entities = []
    for category, keywords in _SCENE_ENTITIES.items():
        for kw in keywords:
            if kw in combined and kw not in found_entities:
                found_entities.append(kw)
    if not found_entities:
        return "", []
    scene = " + ".join(found_entities[:5])
    return scene, found_entities


def _hermes_available() -> bool:
    """快速检测 Hermes Agent 是否可达（5s 超时）。"""
    host = _get_hermes_host()
    if not host:
        return False
    try:
        result = subprocess.run(
            ["ssh", "-o", "ConnectTimeout=3", "-o", "StrictHostKeyChecking=no",
             host, "echo ok"],
            capture_output=True, text=True, timeout=5,
        )
        return result.returncode == 0 and result.stdout.strip() == "ok"
    except Exception:
        return False


def _get_hermes_host() -> str:
    """从 lang_config.json 读取 hermes_host,没配则返回空字符串。

    设计:不写默认值。之前自动写入开发者机器的 mDNS hostname,
    别人电脑首次启动会被塞一个不属于他们的 host → UI 显示"可达"
    但实际不是。现在只读 — 用户没配就空,后续 _hermes_available() 检测
    到空直接返回 False 跳过 Hermes 调用。
    """
    cfg_path = "/tmp/whicc-out/lang_config.json"
    try:
        if os.path.exists(cfg_path):
            with open(cfg_path, "r", encoding="utf-8") as f:
                cfg = json.load(f)
            host = (cfg.get("hermes_host") or "").strip()
            if host:
                return host
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        pass
    return ""


def _resolve_hermes_invoke() -> str:
    """探测远端怎么调用 hermes CLI。

    返回 shell 字符串,e.g. "hermes" (PATH 里有) 或 "~/.local/bin/hermes"
    (用户装的 pipx/uv tool)。缓存到 HERMES_INVOKE 全局变量。

    之前硬编码开发者机器上的绝对 hermes 路径
    (在 .hermes/hermes-agent/venv/bin/python3 启动),那在别人电脑
    会 ssh 到对方机器执行 → 路径不存在 → 静默失败。

    探测顺序:
      1. `~/.local/bin/hermes` (pipx/uv tool 默认安装位置,Mac 普遍)
      2. `which hermes` (PATH 里有,Linux 服务器常见)
      3. 空字符串 (探测失败,调用方返回 None 不报错)
    """
    global HERMES_INVOKE
    if HERMES_INVOKE:
        return HERMES_INVOKE

    home = os.path.expanduser("~")
    candidates = [
        f"{home}/.local/bin/hermes",
        "hermes",  # 依赖 PATH
    ]
    for c in candidates:
        if os.path.isabs(c):
            if os.path.exists(c) and os.access(c, os.X_OK):
                HERMES_INVOKE = c
                return HERMES_INVOKE
        else:
            # 用 shlex 拼 shell 命令,远端 bash 自己解析 PATH
            # 探测只检查格式,不实际 ssh (避免每次启动都慢)
            HERMES_INVOKE = c
            return HERMES_INVOKE
    HERMES_INVOKE = ""
    return ""


def lm_agent_scene_terms(sources: list[str], scene: str, entities: list[str],
                         candidates: list[str] | None = None) -> dict:
    """调用 Mac Mini 的 Hermes Agent 获取场景术语。Hermes 有 web search 能力，比 LM Studio 1.8B 强得多。"""
    now_str = _now_with_tz()
    sample = "\n".join(sources[-15:])

    if any(e in _SCENE_ENTITIES.get("球队", []) + _SCENE_ENTITIES.get("体育", []) for e in entities):
        domain_hint = "体育赛事（球队名、球员名、教练名、战术术语、比赛用语）"
    elif any(e in _SCENE_ENTITIES.get("财经", []) for e in entities):
        domain_hint = "财经金融（机构名、经济指标、金融术语、市场用语）"
    elif any(e in _SCENE_ENTITIES.get("科技", []) for e in entities):
        domain_hint = "科技（公司名、技术术语、产品名、学术概念）"
    else:
        domain_hint = "通用"

    candidates_hint = ""
    if candidates:
        candidates_hint = (
            f"\n以下是从语音转录中提取的候选术语（可能有同音错别字，如'船球'应为'传球'，'中风'应为'中锋'）。"
            f"请先纠正错别字，再翻译为英文：{', '.join(candidates[:20])}。"
        )

    query = (
        f"当前时间：{now_str}。"
        f"用户正在收听/收看的内容涉及：{domain_hint}。"
        f"关键实体：{', '.join(entities[:6])}。"
        f"转录片段：{sample[:500]}。"
        f"{candidates_hint}"
        f"请搜索并列出该场景下最常见的专业术语和专有名词（人名、地名、机构名、领域术语）的中英对照。"
        f"每行一个，格式：中文 = English。至少 15 个。只输出列表，英文翻译不要加括号注释。"
    )

    try:
        host = _get_hermes_host()
        if not host:
            print("[refresher] Hermes 未配置 (lang_config.json 缺 hermes_host),跳过", file=sys.stderr)
            return {}
        invoke = _resolve_hermes_invoke()
        if not invoke:
            print("[refresher] Hermes CLI 未找到 (~/.local/bin/hermes 或 PATH 里都没有),跳过", file=sys.stderr)
            return {}
        result = subprocess.run(
            ["ssh", host,
             f"{invoke} chat -q {shlex.quote(query)} -Q"],
            capture_output=True, text=True, timeout=120,
        )
        if result.returncode != 0:
            print(f"[refresher] Hermes Agent 退出码 {result.returncode}: {result.stderr[:200]}", file=sys.stderr)
            return {}
        output = result.stdout.strip()
        if not output:
            print("[refresher] Hermes Agent 返回空", file=sys.stderr)
            return {}
        print(f"[refresher] Hermes Agent 返回 {len(output)} 字符", flush=True)
        return _parse_term_pairs(output)
    except subprocess.TimeoutExpired:
        print("[refresher] Hermes Agent 超时（120s）", file=sys.stderr)
        return {}
    except Exception as exc:
        print(f"[refresher] Hermes Agent 调用失败: {exc}", file=sys.stderr)
        return {}


def _parse_term_pairs(text: str) -> dict:
    """解析 '中文 = English' 格式的术语列表。"""
    zh2en = {}
    for line in text.strip().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or line.startswith("```"):
            continue
        # 去掉列表符号: "- ", "* ", "1. ", "1) "
        line = re.sub(r'^[\-\*\d]+[\.\)\s]+\s*', '', line)
        m = re.match(r'^(.+?)\s*[=:→]\s*(.+)$', line)
        if not m:
            continue
        zh = m.group(1).strip().strip('"\'')
        en = m.group(2).strip().strip('"\'')
        # 清理括号注释："(中风→中锋，ASR 错字)" → 只保留主体翻译
        en = re.sub(r'\s*[\(（].*?[\)）]\s*$', '', en).strip()
        if len(zh) < MIN_TERM_LEN or len(en) < 2:
            continue
        if zh in _STOPWORDS_ZH:
            continue
        if re.match(r'^[\d\s\.\,\;\:\!\?]+$', zh):
            continue
        # 过滤太长的（整句不是术语）
        if len(zh) > 15 or len(en) > 40:
            continue
        zh2en[zh] = en
    return zh2en


# ── 主循环 ──

def run_once() -> tuple[dict, int]:
    """返回 (实际入库的术语dict, 数量)。"""
    sources = load_events()
    if not sources:
        print("[refresher] 无事件数据，跳过", flush=True)
        return {}, 0

    # Step 1: jieba 提取候选
    candidates = extract_candidates(sources)
    # 过滤已入库的
    glossary = load_glossary()
    existing_zh = set(glossary.get("zh2en", {}).keys())
    new_candidates = [c for c in candidates if c not in existing_zh]

    if not new_candidates:
        print(f"[refresher] {len(candidates)} 个候选，全部已入库，跳过", flush=True)
        return {}, 0

    print(f"[refresher] 候选: {len(candidates)} 个（{len(new_candidates)} 个新）: {', '.join(new_candidates[:8])}...", flush=True)

    # Step 1.5: 场景检测 → 调用 Hermes Agent 获取术语
    # 如果 Hermes Agent 不可达，直接跳过整个术语搜索步骤
    if not _hermes_available():
        print("[refresher] Hermes Agent 不可达，跳过术语搜索", flush=True)
        return {}, 0

    scene, entities = detect_scene(sources)
    translated = {}       # {zh: (en, source)}
    hermes_ok = 0
    if not scene:
        print("[refresher] 未检测到场景，跳过", flush=True)
        return {}, 0

    print(f"[refresher] 检测到场景: {scene}，调用 Hermes Agent...", flush=True)
    hermes_terms = lm_agent_scene_terms(sources, scene, entities, new_candidates)
    if hermes_terms:
        print(f"[refresher] Hermes Agent 返回 {len(hermes_terms)} 个术语", flush=True)
        for zh, en in hermes_terms.items():
            if zh not in existing_zh:
                translated[zh] = (en, "hermes")
                hermes_ok += 1

    if not translated:
        print("[refresher] Hermes Agent 无新术语，跳过", flush=True)
        return {}, 0

    # Step 3: 合并入库 + 记录元数据
    added_count = 0
    added_terms = {}  # {zh: (en, source)} 实际入库的
    now_str = _now_ts()
    zh2en = glossary.setdefault("zh2en", {})
    en2zh = glossary.setdefault("en2zh", {})
    meta = glossary.setdefault("_meta", {})
    skipped = 0
    for zh, (en, source) in translated.items():
        if zh in zh2en:
            continue
        if len(zh2en) >= MAX_GLOSSARY_SIZE:
            continue
        # 验证：zh 必须含 CJK，en 必须不含 CJK
        if not _is_cjk(zh) or _is_cjk(en):
            skipped += 1
            continue
        # 长度合理
        if len(zh) < 2 or len(zh) > 15 or len(en) < 2 or len(en) > 40:
            skipped += 1
            continue
        # 必须是纯中文（不含拉丁字符）
        if re.search(r'[a-zA-Z]', zh):
            skipped += 1
            continue
        zh2en[zh] = en
        en2zh[en] = zh
        meta[zh] = {"source": source, "added": now_str, "last_used": now_str, "hits": 0}
        added_count += 1
        added_terms[zh] = (en, source)
    if skipped:
        print(f"[refresher] 过滤掉 {skipped} 个无效术语", flush=True)

    if added_count >= MIN_NEW_TO_WRITE:
        save_glossary(glossary)
        save_meta(len(candidates), len(translated), added_count, f"hermes:{hermes_ok}", scene)
        total = len(zh2en) + len(en2zh)
        print(f"[refresher] 词库 +{added_count}（hermes:{hermes_ok}），共 {total} 条", flush=True)
        for zh, en in list(added_terms.items())[:10]:
            print(f"  [new] {zh} = {en[0]}", flush=True)
        _log_changes(added_terms, [])
    else:
        print(f"[refresher] 新增 {added_count}，低于阈值，跳过", flush=True)

    return added_terms, added_count


def main():
    print(f"[refresher] 自学习术语优化器 v3（jieba + Hermes Agent）", flush=True)
    print(f"[refresher] 每 {POLL_INTERVAL}s 采样一次", flush=True)
    global _last_cleanup
    while True:
        try:
            # 定期清理过期术语
            now = time.time()
            if now - _last_cleanup > CLEANUP_INTERVAL:
                g = load_glossary()
                removed_terms = cleanup_glossary(g)
                if removed_terms:
                    save_glossary(g)
                    _log_changes({}, removed_terms)
                    print(f"[refresher] 清理过期术语: -{len(removed_terms)}，剩余 {len(g.get('zh2en',{}))} 条", flush=True)
                _last_cleanup = now

            # 暂停检查：overlay 可通过控制文件暂停自学习
            if _is_paused():
                if int(now) % 300 < POLL_INTERVAL:  # 每 ~300s 提示一次
                    print("[refresher] 已暂停（overlay 控制）", flush=True)
            else:
                run_once()
        except Exception as exc:
            print(f"[refresher] 异常: {exc}", file=sys.stderr, flush=True)
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="whicc glossary refresher")
    parser.add_argument(
        "--glossary",
        default=GLOSSARY_PATH,
        help="glossary.json 可写路径（打包模式应指向 Application Support）",
    )
    args = parser.parse_args()

    # 与 macui / translate_stream 共用同一文件；旁路控制文件落在同目录
    GLOSSARY_PATH = os.path.abspath(args.glossary)
    _gdir = os.path.dirname(GLOSSARY_PATH) or "."
    META_PATH = os.path.join(_gdir, "_glossary_meta.json")
    CONTROL_PATH = os.path.join(_gdir, "_glossary_control.json")
    CHANGES_PATH = os.path.join(_gdir, "_glossary_changes.jsonl")
    main()
