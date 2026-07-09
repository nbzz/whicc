#!/usr/bin/env python3
"""whicc - 系统音频实时语音识别,nemotron / qwen3 streaming 直出原文

用法:
    python3 whicc.py [--save-wav DIR] [--dump-raw] [--dump-filtered] [--stats]
    python3 whicc.py --run-id v6_001 --events-jsonl runs/v6_001/events.jsonl --output-text runs/v6_001/final.txt \
        --min-chunk-sec 2.0 --max-chunk-sec 4.5 --overlap-sec 0.5 ...
"""
import sys
import os
import re
import json
import time
import argparse
import subprocess
import shlex
import shutil
import hashlib
import threading
import signal
import queue as queue_mod
from collections import Counter
import numpy as np

# --------------- 配置 ---------------
import sys

# 让 python3 /path/to/src/whicc.py 这种直接调用方式能 import 同目录的
# config.py / audio.py。
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# HF 镜像加速(设置页"下载加速"开关):whicc.py 的模型加载在本地缺模型
# 时会走 huggingface_hub 下载 fallback。HF_ENDPOINT 在 huggingface_hub
# **import 时**固化,必须在任何 hf/mlx_audio import 之前设好。
try:
    with open("/tmp/whicc-out/lang_config.json", encoding="utf-8") as _f:
        if json.load(_f).get("hf_mirror_enabled"):
            os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")
except (OSError, json.JSONDecodeError):
    pass

from config import SEG_DIR, SAMPLE_RATE, BYTES_PER_SAMPLE, SEG_DURATION_SEC
# audiotee 路径：项目内 ./bin/audiotee（持久化,不会像 /tmp 那样被清掉）。
# 之前用的 /tmp/whicc-audio/.build/debug/whicc-audio 路径,二进制
# 容易被系统清理,导致字幕链断。现在改用 ./bin/audiotee,跟 livecaption
# (six-ddc/livecaption) 的设计一致——单文件 Python 进程,内部多线程,
# 音频采集跟 ASR 通过 queue.Queue 解耦。
AUDIO_BIN = "./bin/audiotee"
# 默认 ASR 模型: nemotron streaming (中英共用,英文效果更准;中文会自动切 qwen3)
DEFAULT_MODEL = "mlx-community/nemotron-3.5-asr-streaming-0.6b"
# 兼容老的项目内 models/ 路径（仅做兜底，新代码用 --models-dir 走
# ~/Library/Application Support/whicc/models/）。保留以防用户从老
# 启动脚本启动时崩——但默认指向不存在的相对路径，强制使用 --models-dir。
MODEL_DIR = os.path.join(os.path.dirname(__file__), "..", "models")
QWEN3_MODEL = "mlx-community/Qwen3-ASR-0.6B-4bit"  # 中文备用 ASR

from model_state import (  # noqa: E402  (放在常量后避免循环 import)
    read_model_state, write_model_state,
    resolve_model_id, resolve_models_dir,
)

# 模型预设：不同模型的最佳默认参数
# max_chunk 兜底值: Qwen3 streaming 用 12s, nemotron streaming 用 15s。
MODEL_PRESETS = {
    "Qwen3-ASR":  {"no_speech": 0.50, "min_chunk": 2.0, "max_chunk": 12.0},
    "nemotron":   {"no_speech": 0.50, "min_chunk": 2.0, "max_chunk": 15.0},
}

def _detect_backend(model_path: str) -> str:
    """检测模型后端类型：'nemotron' 或 'qwen3'。"""
    name = os.path.basename(model_path).lower()
    if "nemotron" in name:
        return "nemotron"
    return "qwen3"

# 自适应 chunk (对齐 livecaption 策略,2026-06-28)
#   min=2.0, soft_max=8.0, max=20.0 (兜底), punct=0.6s, silence=1.2s
#   核心改进: SILENCE_SUBMIT_SEC 0.4→1.2 — 思考停顿不再被当句尾
#   SOFT_MAX_SEC 4.6→8.0 — 长演讲累积够立刻在标点切,不强制切半
# 字幕触发参数 (平衡"快速显示" vs "完整句不切碎"):
# - PUNCT_END_MIN_CHUNK_SEC_EN=3.0 / _ZH=5.0: 累积够才检查标点,中文阈值更高
#   (中文 ASR streaming 容易幻觉句末标点,需要更多上下文才稳)。
# - SOFT_MAX_SEC = 5.0: 累积 5s 还没切 → 强制在中间标点切,防止字幕延迟
#   触发阈值的语言分层:
#   - 英文场景: ASR streaming 在 3s 累积的 sm_text 末尾标点 ≈ 真实句末 (测试: commit 6cf8d9d 100% 强句末)
#   - 中文场景: ASR 容易"幻觉"句末标点 (3s 仅 10-15 字时频繁误判),需要更长阈值
#   PUNCT_END_MIN_CHUNK_SEC_EN / _ZH 在 probe ASR 拿到 language 后动态选。
PUNCT_END_MIN_CHUNK_SEC_EN = 3.0   # 英文 (Nemotron 在英文 streaming 上 3s 标点可靠)
PUNCT_END_MIN_CHUNK_SEC_ZH = 5.0   # 中文 (Qwen3-ASR 中文 streaming 需要更多上下文)
STRONG_END_PUNCT = "。！？.!?"   # 强句末标点: 切这里一定是完整句
# 中文额外字符数校验: 标点出现位置的前一个字符往前数 >= 12 字符才算完整句。
# 短句 (< 12 字) 即使末尾有 `。` 也疑似 ASR 幻觉 (e.g. "美联。" 3 字就是截断)。
MIN_CHARS_BEFORE_PUNCT_ZH = 12
MIN_CHARS_BEFORE_PUNCT_EN = 8

MIN_CHUNK_SEC = 2.0
MAX_CHUNK_SEC = 10.0   # 兜底值,避免无限累积
SOFT_MAX_SEC = 5.0     # 软最大值:长句(无标点)兜底。新触发器优先切句末标点
SILENCE_THRESHOLD = 0.01  # RMS
PUNCT_SUBMIT_SEC = 0.6   # 句末标点结尾时更快提交
SILENCE_SUBMIT_SEC = 1.2  # 中间停顿等更久,避免思考停顿被切半
POLL_INTERVAL = 0.15       # 段文件轮询间隔
OVERLAP_SEC = 0.3          # chunk 间重叠

# 过滤
ALLOWED_LANG = {"en", "zh", "ja", "ko", "de", "fr", "es", "pt", "it"}
MIN_LOGPROB = -1.0
MAX_COMPRESSION = 2.4
MIN_SPEECH_SEC = 0.5       # 太短的 chunk 直接丢弃

# ASR 调优
NO_SPEECH_THRESHOLD = 0.45
INITIAL_PROMPT = ""

HALLUCINATION_PHRASES = [
    "субтитры", "dimatorzok", "подписал", "перевод",
    "subscribe", "like and subscribe", "thanks for watching",
]

# 短文本幻觉：长度 ≤ 阈值 且不包含有意义内容的转录
HALLUCINATION_SHORT_MAX_LEN = 5

# Prompt 模式
PROMPT_MODE_FIXED = "fixed"
PROMPT_MODE_TAIL = "tail"
PROMPT_MODE_NONE = "none"

# Reject reason 枚举
REJECT_SHORT_CHUNK = "short_chunk"
REJECT_HALLUCINATION = "hallucination"
REJECT_LANG = "lang"
REJECT_LOGPROB = "logprob"
REJECT_COMPRESSION = "compression"
REJECT_EMPTY = "empty_text"

# --------------- 过滤 ---------------

# 常见 ASR 转写错误修正 (大小写、专有名词)
CORRECTIONS = {
    "chatgpt": "ChatGPT",
    "openai": "OpenAI",
    "anthropic": "Anthropic",
    "claude": "Claude",
    "dario": "Dario",
    "daniela": "Daniela",
    "amodei": "Amodei",
    "altman": "Altman",
    "stripe": "Stripe",
    "baidu": "Baidu",
    "palantir": "Palantir",
    "karnofsky": "Karnofsky",
    "hegseth": "Hegseth",
    "maduro": "Maduro",
    "oppenheimer": "Oppenheimer",
    "calypso": "Calypso",
    "mythos": "Mythos",
    "glasswing": "Glasswing",
    "precita": "Precita",
}

# 句首重复词清理 (ASR streaming 偶尔会重复短语)
SENTENCE_START_REPEATS = [
    r'^(I said,?\s+I said,?\s+)',
    r'^(and so,?\s+and so,?\s+)',
    r'^(but you know,?\s+but you know,?\s+)',
    r'^(so,?\s+so,?\s+so,?\s+)',
]

def postprocess(text: str) -> str:
    """修正常见 ASR 转写错误"""
    # 句首重复清理
    for pattern in SENTENCE_START_REPEATS:
        text = re.sub(pattern, lambda m: m.group(1)[len(m.group(1))//2:], text, flags=re.IGNORECASE)

    words = text.split()
    fixed = []
    for w in words:
        low = w.lower().strip('.,!?;:')
        if low in CORRECTIONS:
            # 提取词首非字母前缀和词尾非字母后缀
            first = next((i for i, c in enumerate(w) if c.isalpha()), len(w))
            last = next((i for i, c in enumerate(reversed(w)) if c.isalpha()), len(w))
            prefix = w[:first]
            suffix = w[len(w)-last:] if last > 0 else ''
            fixed.append(prefix + CORRECTIONS[low] + suffix)
        else:
            fixed.append(w)
    return ' '.join(fixed)

def is_hallucination(text: str) -> bool:
    t = text.strip()
    if not t:
        return True
    if len(t) > 8:
        for i in range(1, min(6, len(t) // 3)):
            if t[:i] * 3 in t:
                return True
    low = t.lower()
    for p in HALLUCINATION_PHRASES:
        if p in low:
            return True
    # word-level 长句重复检测（抓 "This is a conversation about AI..." 类幻觉）
    words = low.split()
    if len(words) >= 12:
        for n in range(3, min(9, len(words) // 3 + 1)):
            ngrams = [" ".join(words[i:i+n]) for i in range(len(words) - n + 1)]
            if not ngrams:
                continue
            counts = Counter(ngrams)
            most_common, most_count = counts.most_common(1)[0]
            if most_count >= 3:
                return True
    return False

# --------------- Nemotron / Qwen3 ---------------
# (曾经这里有 save_wav — 每次推理先把 float32 量化成 int16 写临时 WAV
# 再让模型读回。现在音频数组直传 generate(见 do_transcribe),整条管线
# 零磁盘往返,且保留 float32 全精度,不再有 int16 量化损失。)

_qwen3_model = None  # 预加载的 Qwen3 模型（懒初始化）

# 启动期模型加载错误（RepositoryNotFoundError / 网络 / disk） — 用这
# 个标记告诉 main() "模型加载失败,切回 Nemotron 默认"。
_model_load_failed = False
_model_load_error_msg = ""


def _get_qwen3_model(model_path: str):
    """懒加载 Qwen3 ASR 模型，只加载一次。失败时把全局 _model_load_failed 置上,
    main() 会回退到 Nemotron 默认而不是让进程 crash 掉。"""
    global _qwen3_model, _model_load_failed, _model_load_error_msg
    if _qwen3_model is None:
        from mlx_audio.stt import load_model
        try:
            _qwen3_model = load_model(model_path)
        except Exception as e:
            _model_load_failed = True
            _model_load_error_msg = f"Qwen3 model load failed: {model_path} - {e}"
            print(f"[model-load] {_model_load_error_msg}", file=sys.stderr, flush=True)
            raise
    return _qwen3_model


def _unload_qwen3():
    global _qwen3_model
    _qwen3_model = None


def _async_load_model(which: str, model_path: str, ready_event: threading.Event):
    """后台线程：加载模型，完成后 warmup（避免第一次推理编译 Metal kernel 卡住）"""
    try:
        if which == "qwen3":
            _get_qwen3_model(model_path)
            _warmup_model(model_path, "qwen3")
        else:
            _get_nemotron_model(model_path)
            _warmup_model(model_path, "nemotron")
    except Exception as e:
        print(f"[lang-switch] 异步加载失败: {e}", file=sys.stderr, flush=True)
    finally:
        ready_event.set()


def _warmup_model(model_path: str, which: str) -> None:
    """对刚加载的模型做一次空推理 warmup（吸收 Metal kernel 编译延迟）。
    数组直传,不经临时 WAV。"""
    samples = np.zeros(int(SAMPLE_RATE * 0.5), dtype=np.float32)
    try:
        if which == "qwen3":
            _do_transcribe_qwen3(samples, language="auto", model_path=model_path)
        else:
            _do_transcribe_nemotron(samples, language="auto", model_path=model_path)
    except Exception:
        pass


def do_transcribe(audio, language: str = "en",
                  model: str = DEFAULT_MODEL,
                  backend: str = "nemotron") -> dict:
    """转录（非流式）。backend: 'nemotron' 或 'qwen3'。

    audio: WAV 路径(str) 或 float32 mono 16kHz 的 np.ndarray —
    两个后端的 generate 都原生支持数组输入(Nemotron 收 mx.array,
    Qwen3 直接收 ndarray),数组直传省掉"每次推理先写 WAV 再读回"
    的磁盘往返(探针每 0.6s 一次)。
    """
    if backend == "qwen3":
        return _do_transcribe_qwen3(audio, language=language, model_path=model)
    return _do_transcribe_nemotron(audio, language=language, model_path=model)


def _do_transcribe_qwen3(audio, language: str = "en", model_path: str = "") -> dict:
    """Qwen3 ASR 转录。audio: WAV 路径或 float32 16kHz ndarray
    (Qwen3ASRModel.generate 原生接受 ndarray,采样率假定 16k 与
    load_audio 默认一致)。"""
    m = _get_qwen3_model(model_path)
    r = m.generate(audio, language=language, verbose=False)

    text = r.text.strip() if r.text else ""
    # Qwen3 返回 language=['en']（列表），取第一个 — 但这个字段经常不准 (e.g. 中文
    # audio 仍返回 "en"),需要从文本字符判断。
    raw_lang = r.language[0] if isinstance(r.language, list) else (r.language or language)
    if language in ("auto", ""):
        # auto 模式下从文本判断: cjk > 30% → zh,否则用 raw_lang / "en"
        cjk_count = sum(1 for c in text if "一" <= c <= "鿿")
        if cjk_count > max(3, len(text) * 0.3):
            lang = "zh"
        else:
            lang = "en" if raw_lang in ("auto", "") else raw_lang
    else:
        # 显式指定了 language (e.g. "zh"),信任用户配置
        lang = "en" if raw_lang in ("auto", "") else raw_lang
    segs = r.segments or []

    # Qwen3 segments 没有 avg_logprob/compression_ratio/no_speech_prob
    # 用文本长度和 segment 数量做粗略估计
    avg_lp = -0.3 if text else -99    # Qwen3 没有 logprob，给个合理的默认值
    avg_cr = 0.0
    avg_nsp = 0.0 if text else 1.0

    return {"text": text, "language": lang, "avg_logprob": avg_lp,
            "avg_compression": avg_cr, "no_speech_prob": avg_nsp}



def filter_result(result: dict) -> tuple:
    """判断转录结果是否通过过滤。返回 (reject_reason, postprocessed_text)，通过时 reject_reason=None"""
    text = result["text"]
    lang = result["language"]
    if not text:
        return REJECT_EMPTY, None
    # 单字幻觉：整句话就一个常见词（如 "The." "See." "You."），不是句子中有 the
    stripped = text.strip().rstrip(".!?")
    if len(stripped) <= 4 and stripped.lower() in {"the", "see", "you", "a", "oh", "so", "and", "but", "is"}:
        return REJECT_HALLUCINATION, None
    if lang not in ALLOWED_LANG:
        return REJECT_LANG, None
    if result["avg_logprob"] < MIN_LOGPROB:
        return REJECT_LOGPROB, None
    if result["avg_compression"] > MAX_COMPRESSION:
        return REJECT_COMPRESSION, None
    if is_hallucination(text):
        return REJECT_HALLUCINATION, None
    return None, postprocess(text)

# --------------- Nemotron ASR ---------------

_nemotron_model = None

def _unload_nemotron():
    global _nemotron_model
    _nemotron_model = None

def _get_nemotron_model(model_path: str):
    """懒加载 Nemotron ASR 模型。失败时同样置 _model_load_failed。"""
    global _nemotron_model, _model_load_failed, _model_load_error_msg
    if _nemotron_model is None:
        from mlx_audio.stt import load_model
        try:
            _nemotron_model = load_model(model_path)
        except Exception as e:
            _model_load_failed = True
            _model_load_error_msg = f"Nemotron model load failed: {model_path} - {e}"
            print(f"[model-load] {_model_load_error_msg}", file=sys.stderr, flush=True)
            raise
    return _nemotron_model


def _do_transcribe_nemotron(audio, language: str = "en",
                            model_path: str = "") -> dict:
    """Nemotron ASR 转录（非流式）。language='auto' 或空时自动检测。
    audio: WAV 路径或 float32 16kHz ndarray(generate 收 mx.array,
    ndarray 在这里转一层 — mx.array 包装零拷贝级开销)。"""
    m = _get_nemotron_model(model_path)
    if isinstance(audio, np.ndarray):
        import mlx.core as mx
        audio = mx.array(audio)
    lang_param = None if language in ("auto", "") else language
    r = m.generate(audio, language=lang_param)
    text = r.text.strip() if r.text else ""
    sentences = r.sentences if hasattr(r, 'sentences') else []
    avg_lp = -0.3
    avg_cr = 0.0
    avg_nsp = 0.0
    # Nemotron 不返回检测到的语言 — 从文本字符判断: 中文字符 > 30% 视为中文。
    # 这是必须的: 否则 probe ASR 永远返回 "en",trigger 永远用英文阈值 (3s),
    # 中文 3s 累积时 ASR 幻觉 `。` 会触发 mid-sentence 切割。
    if language not in ("auto", ""):
        detected_lang = language
    else:
        cjk_count = sum(1 for c in text if "一" <= c <= "鿿")
        detected_lang = "zh" if cjk_count > max(3, len(text) * 0.3) else "en"
    return {"text": text, "language": detected_lang, "avg_logprob": avg_lp,
            "avg_compression": avg_cr, "no_speech_prob": avg_nsp,
            "sentences": sentences}


# --------------- 语言检测 ---------------

CJK_OBSERVE_LOW = 0.3    # 进入观察区
CJK_SWITCH_HIGH = 0.55   # 确认中文，触发切换

def _detect_qwen_lang(text: str) -> str | None:
    """检测是否应切换到 Qwen3。返回 'zh' / 'ja' / None。
    中文：CJK 字符占比 > 0，无日韩字符
    日文：含平假名或片假名
    """
    if not text:
        return None
    has_hira = any('ぁ' <= c <= 'ん' for c in text)
    has_kata = any('ァ' <= c <= 'ヶ' for c in text)
    has_hangul = any(('가' <= c <= '힣') or ('ㄱ' <= c <= 'ㅎ') for c in text)
    if has_hangul:
        return None  # 韩文不切
    if has_hira or has_kata:
        return 'ja'
    cn_count = sum(1 for c in text if '一' <= c <= '鿿')
    if cn_count / max(len(text), 1) > 0:
        return 'zh'
    return None

def _cjk_ratio(text: str) -> float:
    """返回文本中 CJK 字符的占比（用于中文观察区阈值判断）"""
    if not text:
        return 0.0
    cn_count = sum(1 for c in text if '一' <= c <= '鿿')
    return cn_count / len(text)

# --------------- 增量去重 ---------------

def incremental_text(old: str, new: str) -> str:
    """返回 new 相对于 old 的增量部分（word-level 最长公共前后缀匹配）"""
    if not old:
        return new
    old_words = old.split()
    new_words = new.split()
    best = 0
    for k in range(1, min(len(old_words), len(new_words)) + 1):
        if old_words[-k:] == new_words[:k]:
            best = k
    return " ".join(new_words[best:])

# --------------- 软最大值断句辅助 ---------------

SENTENCE_END_PUNCT = set("。！？.!?")
MID_PUNCT = set("，、；：,;:")  # 中间标点：文字过长时也可作为切割点
SOFT_MAX_MIN_CHARS = 35  # 文字超过此长度时，中间标点也可切割
SOFT_MAX_ASR_COOLDOWN = 0.6  # 软最大值 ASR 重试冷却（秒）

def find_audio_split_sec(text: str, total_sec: float, segments: list | None = None,
                         punct_set: set | None = None,
                         min_char_pos: int = 0) -> float:
    """找到 text 中 min_char_pos 之后最后一个标点对应的音频时间位置（秒）。
    优先使用 ASR segments 时间戳（精确），否则按字符比例估算。
    返回 0 表示没找到标点，不应分割。
    punct_set: 要搜索的标点集合，默认 SENTENCE_END_PUNCT
    min_char_pos: 忽略此位置之前的标点（避免切太短）
    """
    if punct_set is None:
        punct_set = SENTENCE_END_PUNCT
    last_punct_pos = -1
    for i in range(len(text) - 1, min_char_pos - 1, -1):
        if text[i] in punct_set:
            last_punct_pos = i
            break
    if last_punct_pos < 0:
        return 0.0

    # 方案 A: 用 ASR segments 时间戳 (精确)
    if segments:
        char_pos = 0
        for seg in segments:
            seg_text = seg.get("text", "")
            seg_start = char_pos
            seg_end = char_pos + len(seg_text)
            if last_punct_pos >= seg_start and last_punct_pos < seg_end:
                return seg.get("end", 0.0)
            char_pos = seg_end
        # fallback：标点在最后一个 segment
        if segments:
            return segments[-1].get("end", total_sec)

    # 方案 B：字符比例估算
    return total_sec * (last_punct_pos + 1) / len(text)

# --------------- 段文件消费 ---------------

def cleanup_seg_dir():
    os.makedirs(SEG_DIR, exist_ok=True)
    for f in os.listdir(SEG_DIR):
        if f.endswith(".pcm"):
            try:
                os.unlink(os.path.join(SEG_DIR, f))
            except OSError:
                pass

def read_segments(next_seg: int) -> tuple[list[bytes], int]:
    """读取所有可用段文件，返回 (数据列表, 下一个序号)"""
    chunks = []
    while True:
        path = os.path.join(SEG_DIR, f"seg-{next_seg:06d}.pcm")
        if not os.path.exists(path):
            break
        try:
            with open(path, "rb") as f:
                data = f.read()
            os.unlink(path)
        except (OSError, IOError):
            break
        if data:
            chunks.append(data)
        next_seg += 1
    return chunks, next_seg

def drain_audio_queue(q: "queue_mod.Queue",
                      first_timeout: float) -> list[np.ndarray]:
    """live 模式(system/mic)的读取路径:直接消费 AudioSource.queue。

    阻塞至多 first_timeout 等首个 chunk,拿到后无等待排空当前可用的
    全部 chunks。chunk 到达即返回(采集回调粒度 ~0.1s),替代旧的
    SegDirWriter→/tmp 段文件→read_segments 磁盘往返(1s 段聚合 +
    0.15s 轮询,每段最多 +1.15s 延迟,且 /tmp 被系统清理会断链)。

    SENTINEL(None) = 当前 source 流结束(audio swap 时旧 source 冲刷
    完毕)——丢弃并停止 drain,下一轮主循环读到的是(swap 后的)新
    source.queue。
    """
    chunks: list[np.ndarray] = []
    try:
        first = q.get(timeout=first_timeout)
        if first is None:
            return chunks
        chunks.append(first)
        while True:
            nxt = q.get_nowait()
            if nxt is None:
                break
            chunks.append(nxt)
    except queue_mod.Empty:
        pass
    return chunks

# --------------- Event Logger ---------------

class EventLogger:
    """JSONL 结构化事件日志器"""

    def __init__(self, path: str):
        self.path = path
        if path:
            dirname = os.path.dirname(path)
            if dirname:
                os.makedirs(dirname, exist_ok=True)
            self._f = open(path, "a", encoding="utf-8")
        else:
            self._f = None

    def write(self, event: dict):
        if self._f:
            self._f.write(json.dumps(event, ensure_ascii=False) + "\n")
            self._f.flush()

    def log_status(self, status: str, **extra):
        event = {"event_type": "status", "status": status}
        event.update(extra)
        self.write(event)

    def log_reject(self, seg_start, seg_end, audio_start_sec, audio_end_sec, chunk_sec,
                   submit_wall_time, prompt_mode, prompt_chars, reject_reason,
                   submit_reason="", buffered_sec=0, speech_sec=0,
                   trailing_silence_sec=0, prompt_hash="", tail_source_chars=0,
                   language="", avg_logprob=0, avg_compression=0, no_speech_prob=0,
                   text=""):
        self.write({
            "event_type": "reject",
            "text": text,
            "seg_start": seg_start,
            "seg_end": seg_end,
            "audio_start_sec": round(audio_start_sec, 3),
            "audio_end_sec": round(audio_end_sec, 3),
            "chunk_sec": round(chunk_sec, 3),
            "submit_wall_time": round(submit_wall_time, 3),
            "prompt_mode": prompt_mode,
            "prompt_chars": prompt_chars,
            "reject_reason": reject_reason,
            "submit_reason": submit_reason,
            "buffered_sec": round(buffered_sec, 3),
            "speech_sec": round(speech_sec, 3),
            "trailing_silence_sec": round(trailing_silence_sec, 3),
            "prompt_hash": prompt_hash,
            "tail_source_chars": tail_source_chars,
            "language": language,
            "avg_logprob": round(avg_logprob, 4),
            "avg_compression": round(avg_compression, 4),
            "no_speech_prob": round(no_speech_prob, 4),
            "accepted": False,
        })

    def log_final(self, seg_start, seg_end, audio_start_sec, audio_end_sec, chunk_sec,
                  submit_wall_time, final_wall_time, transcribe_ms,
                  prompt_mode, prompt_chars, text,
                  submit_reason="", buffered_sec=0, speech_sec=0,
                  trailing_silence_sec=0, prompt_hash="", tail_source_chars=0,
                  asm_ms=0, postproc_ms=0,
                  language="", avg_logprob=0, avg_compression=0, no_speech_prob=0):
        event = {
            "event_type": "final",
            "seg_start": seg_start,
            "seg_end": seg_end,
            "audio_start_sec": round(audio_start_sec, 3),
            "audio_end_sec": round(audio_end_sec, 3),
            "chunk_sec": round(chunk_sec, 3),
            "submit_wall_time": round(submit_wall_time, 3),
            "final_wall_time": round(final_wall_time, 3),
            "transcribe_ms": round(transcribe_ms, 1),
            "asm_ms": round(asm_ms, 1),
            "postproc_ms": round(postproc_ms, 1),
            "relative_confirm_latency_sec": round(final_wall_time - submit_wall_time, 3),
            "prompt_mode": prompt_mode,
            "prompt_chars": prompt_chars,
            "submit_reason": submit_reason,
            "buffered_sec": round(buffered_sec, 3),
            "speech_sec": round(speech_sec, 3),
            "trailing_silence_sec": round(trailing_silence_sec, 3),
            "prompt_hash": prompt_hash,
            "tail_source_chars": tail_source_chars,
            "text": text,
            "language": language,
            "avg_logprob": round(avg_logprob, 4),
            "avg_compression": round(avg_compression, 4),
            "no_speech_prob": round(no_speech_prob, 4),
            "accepted": True,
        }
        self.write(event)

    def log_partial(self, seg_start: int, seg_end: int,
                    audio_start_sec: float, audio_end_sec: float,
                    text: str):
        self.write({
            "event_type": "partial",
            "seg_start": seg_start,
            "seg_end": seg_end,
            "audio_start_sec": round(audio_start_sec, 3),
            "audio_end_sec": round(audio_end_sec, 3),
            "text": text,
            "accepted": False,
        })

    def close(self):
        if self._f:
            self._f.close()

# --------------- Metrics ---------------

class Metrics:
    def __init__(self, enabled: bool):
        self.enabled = enabled
        self.chunks = 0
        self.rejects = 0
        self.total_transcribe_ms = 0.0
        self.total_chunk_sec = 0.0
        self.last_report = time.monotonic()

    def record(self, transcribe_ms: float, chunk_sec: float):
        if not self.enabled:
            return
        self.chunks += 1
        self.total_transcribe_ms += transcribe_ms
        self.total_chunk_sec += chunk_sec
        now = time.monotonic()
        if now - self.last_report >= 30:
            self.report()
            self.last_report = now

    def record_reject(self):
        if self.enabled:
            self.rejects += 1

    def report(self):
        if not self.enabled or self.chunks == 0:
            return
        avg_t = self.total_transcribe_ms / self.chunks / 1000
        avg_c = self.total_chunk_sec / self.chunks
        print(f"\n[stats] chunks={self.chunks} rejects={self.rejects} "
              f"avg_transcribe={avg_t:.1f}s avg_chunk={avg_c:.1f}s",
              file=sys.stderr, flush=True)

# --------------- 主循环 ---------------

def main():
    parser = argparse.ArgumentParser(description="whicc - 系统音频实时语音识别")
    # 原有参数
    parser.add_argument("--save-wav", metavar="DIR", help="[未实现] 保存每个 chunk 的 WAV 到指定目录")
    parser.add_argument("--dump-raw", action="store_true", help="stderr 输出 ASR 原始结果")
    parser.add_argument("--dump-filtered", action="store_true", help="stderr 输出过滤后结果")
    parser.add_argument("--stats", action="store_true", help="输出性能指标摘要")
    # 新增：扫参参数
    parser.add_argument("--run-id", default="local", help="运行 ID，用于输出目录命名")
    parser.add_argument("--min-chunk-sec", type=float, default=MIN_CHUNK_SEC)
    parser.add_argument("--max-chunk-sec", type=float, default=MAX_CHUNK_SEC)
    parser.add_argument("--overlap-sec", type=float, default=OVERLAP_SEC)
    parser.add_argument("--silence-threshold", type=float, default=SILENCE_THRESHOLD)
    parser.add_argument("--silence-submit-sec", type=float, default=SILENCE_SUBMIT_SEC)
    parser.add_argument("--no-speech-threshold", type=float, default=NO_SPEECH_THRESHOLD)
    parser.add_argument("--temperature", default="0.0", help="温度，逗号分隔，如 '0.0' 或 '0.0,0.2'")
    parser.add_argument("--prompt-mode", choices=[PROMPT_MODE_FIXED, PROMPT_MODE_TAIL, PROMPT_MODE_NONE],
                        default=PROMPT_MODE_TAIL, help="prompt 策略（默认 tail）")
    parser.add_argument("--prompt-tail-chars", type=int, default=160, help="tail 模式截取确认文本字符数")
    parser.add_argument("--initial-prompt", default=INITIAL_PROMPT, help="Qwen3 ASR initial_prompt 基底文本")
    parser.add_argument("--language", default="en", help="源语言（默认 en；qwen3 可设为 auto 让模型自动识别）")
    parser.add_argument("--model", default=DEFAULT_MODEL,
                        help=f"ASR 模型 ID 或本地路径（默认 {DEFAULT_MODEL}，"
                             f"但优先级低于 --model-state）")
    parser.add_argument("--model-state", default="",
                        help="[BackendLauncher 内部用] model_state.json 路径，"
                             "其中的 current_model 覆盖 --model")
    parser.add_argument("--models-dir", default="",
                        help="[BackendLauncher 内部用] 本地模型目录（~/Library/.../whicc/models/）")
    # 新增：结构化输出
    parser.add_argument("--events-jsonl", metavar="FILE", help="JSONL 事件日志路径")
    parser.add_argument("--output-text", metavar="FILE", help="final-only 输出文件路径")
    parser.add_argument("--audio-bin", default=AUDIO_BIN, help="音频捕获二进制路径（audiotee）")
    parser.add_argument("--audio-source", default="system",
                        choices=["system", "mic", "segdir"],
                        help="音频源:system=截取系统声音(默认,audiotee),"
                             "mic=麦克风(sounddevice),"
                             "segdir=轮询 SEG_DIR 段文件(离线评估,"
                             "由 tools/whicc_file_audio.py 等外部进程投喂)")
    parser.add_argument("--mic-device", default=None,
                        help="麦克风设备索引或名字(传给 sounddevice);默认系统默认")
    parser.add_argument("--dual-model", action="store_true",
                        help="预加载 Nemotron + Qwen3 双模型（中文秒切，耗内存）")
    args = parser.parse_args()

    # 解析模型路径：优先级 model_state.json > --model 参数 > 内置默认
    # 与 review #1/#3 修过的 lang_config 模式一致——只动自己关心的字段。
    # models_dir 来源：--models-dir > model_state.json > 老项目内 MODEL_DIR（兜底）
    state = read_model_state(args.model_state) if args.model_state else {}
    models_dir = args.models_dir or resolve_models_dir(state, MODEL_DIR)
    if state:
        args.model = resolve_model_id(state)
        print(f"[model-state] current_model={args.model}", flush=True)
    resolved_model = args.model
    # 之前用老 MODEL_DIR（项目内 ../models/）拼路径，导致 --models-dir
    # 形同虚设。修：用上一步算出的 models_dir（--models-dir > model_state > 兜底）。
    local_model = os.path.join(models_dir, args.model.replace("/", "--"))
    if os.path.isdir(local_model):
        resolved_model = local_model
        print(f"使用本地模型: {resolved_model}", flush=True)
    elif os.path.isdir(args.model):
        resolved_model = args.model
        print(f"使用本地模型: {resolved_model}", flush=True)
    else:
        print(f"使用 HF 模型: {resolved_model}", flush=True)

    # 自动应用模型预设（CLI 参数优先，预设做默认值）
    preset = None
    for name, p in MODEL_PRESETS.items():
        if name in resolved_model:
            preset = p
            break
    if preset:
        if args.no_speech_threshold == 0.45:  # 还是默认值，用预设覆盖
            args.no_speech_threshold = preset["no_speech"]
        if args.min_chunk_sec == 2.0:
            args.min_chunk_sec = preset["min_chunk"]
        if args.max_chunk_sec == 5.5:
            args.max_chunk_sec = preset["max_chunk"]
        print(f"  预设: no_speech={args.no_speech_threshold}, chunk={args.min_chunk_sec}-{args.max_chunk_sec}s", flush=True)

    # 检测后端类型
    resolved_backend = _detect_backend(resolved_model)
    print(f"  后端: {resolved_backend}", flush=True)

    # 音频源:
    #  - system/mic: 进程内采集线程,主循环直接消费内存 queue(无磁盘往返)
    #  - segdir:     外部进程写 SEG_DIR 段文件(tools/whicc_file_audio.py
    #                离线评估),主循环轮询 read_segments() — 文件协议只保留
    #                在这条评估入口
    from audio import make_source
    use_segdir = args.audio_source == "segdir"
    audio_source = None
    if not use_segdir:
        audio_source = make_source(
            mode=args.audio_source,
            audiotee_path=args.audio_bin,
            mic_device=args.mic_device,
        )

    # 初始化日志器（在模型加载前，这样 status 事件能被 overlay 接收）
    logger = EventLogger(args.events_jsonl)
    logger.log_status("loading_model")

    # ── 启动加速: 音频采集先行 ──
    # 采集在模型加载/warmup(共 3-5s)期间并行进行,音频进 source.queue
    # 积累(容量 ~20s,远大于加载时长)。主循环开始时已有存量音频可
    # 处理 → 首条字幕出现时间提前 ≈ 整个模型加载时长。
    # 之前的顺序是 加载模型 → warmup → 启动采集,用户开 app 后说的
    # 前几秒话全部丢失。
    # status 事件序列(loading_model → ready → listening)保持不变,
    # macui 的 banner 逻辑无感知。
    if not use_segdir:
        try:
            audio_source.start()
        except RuntimeError as e:
            print(f"音频源启动失败: {e}", file=sys.stderr)
            sys.exit(1)

    def _exit_with_audio_cleanup(code: int):
        """模型加载失败退出前把已启动的采集收干净
        (audiotee 子进程 / sounddevice stream)。"""
        if audio_source is not None:
            try:
                audio_source.stop()
            except Exception:  # noqa: BLE001
                pass
        sys.exit(code)

    #   whicc.py 不应该 crash 整个进程。fallback 路径:
    #   qwen3 加载失败 → 切 nemotron 默认 (本地路径优先)
    #   nemotron 加载失败 → 强制走本地路径,跳过 HF download
    fallback_used = False
    try:
        if resolved_backend == "qwen3":
            print("正在加载 Qwen3 ASR 模型...", flush=True)
            _get_qwen3_model(resolved_model)
        else:  # nemotron (默认)
            print("正在加载 Nemotron ASR 模型...", flush=True)
            _get_nemotron_model(resolved_model)
    except Exception:
        # 第一次加载失败。fallback: nemotron 本地路径 (不走 HF)
        fallback_used = True
        _model_load_failed = False  # 重置,允许 fallback 重试
        local_nemotron = os.path.join(
            models_dir, DEFAULT_MODEL.replace("/", "--")
        )
        if os.path.isdir(local_nemotron):
            print(f"[fallback] 切到本地 nemotron: {local_nemotron}", flush=True)
            try:
                _get_nemotron_model(local_nemotron)
                resolved_model = local_nemotron
                resolved_backend = "nemotron"
                # 写 model_state.json 把 current_model 也修了,
                # 下次启动不再踩这个坑。
                write_model_state(
                    args.model_state, models_dir, DEFAULT_MODEL
                )
                logger.log_status("model_fallback")
            except Exception as e2:
                # 连 fallback 都失败 — 致命错误, 但仍然 log 给 macui,
                # 不让进程静默 crash。
                print(
                    f"[model-load] FATAL both primary and fallback "
                    f"model load failed: {e2}",
                    file=sys.stderr,
                    flush=True,
                )
                logger.log_status("model_load_failed")
                logger.log_status(str(e2))
                # 不 raise — 让 whicc.py 干净退出留下 log 痕迹,
                # macui 能读到 model_load_failed status 提示用户。
                # exit 3 = "等模型"(未下载/残缺),不是程序故障 —
                # BackendLauncher 监控按 code 区分:3 → 提示用户去下载
                # + 检测到模型下载完成后立即重启;其他 → 崩溃重启。
                _exit_with_audio_cleanup(3)
        else:
            # 本地也没下载 nemotron → 让用户去 macui 下载
            print(f"[model-load] 本地 nemotron 不存在: {local_nemotron}",
                  file=sys.stderr, flush=True)
            print(f"[model-load]   请在 macui 设置里下载模型",
                  file=sys.stderr, flush=True)
            logger.log_status("model_load_failed")
            logger.log_status(f"local nemotron not found at {local_nemotron}")
            _exit_with_audio_cleanup(3)  # 3 = 等模型,见上方注释

    if fallback_used:
        print(f"[model-load] fallback 成功,继续运行", flush=True)

    # 如果用 nemotron，根据模式决定是否预加载 Qwen3
    nemotron_model = resolved_model if resolved_backend == "nemotron" else ""
    qwen3_fallback = None
    zh_streak = 0           # 连续中文检测计数
    ja_streak = 0           # 连续日文检测计数
    en_streak = 0           # 连续非中日文计数（切回 Nemotron 需要更高阈值）
    pending_switch = None   # "to_qwen3" / "to_nemotron" / None（异步加载中）
    switch_ready = threading.Event()  # 异步加载完成信号
    if resolved_backend == "nemotron":
        qwen3_local = os.path.join(models_dir, QWEN3_MODEL.replace("/", "--"))
        qwen3_path = qwen3_local if os.path.isdir(qwen3_local) else QWEN3_MODEL
        if args.dual_model:
            print(f"预加载 Qwen3 中文备用（双模型模式）: {qwen3_path}", flush=True)
            qwen3_fallback = _get_qwen3_model(qwen3_path)
        else:
            print(f"Qwen3 中文备用就绪（单模型模式，按需加载）: {qwen3_path}", flush=True)
            qwen3_fallback = True  # 标记可用，但不预加载

    # 模型 warmup：对空音频跑一次推理，吸收 Metal kernel 编译延迟
    # (数组直传,不再经临时 WAV 落盘)
    print("模型预热中...", flush=True)
    _warmup_samples = np.zeros(int(SAMPLE_RATE * 0.5), dtype=np.float32)
    try:
        do_transcribe(_warmup_samples, language="en",
                      model=resolved_model, backend=resolved_backend)
    except Exception:
        pass

    # 注:BackendLauncher.waitForASRReady 扫日志找"模型就绪"关键词,
    # 这行文案不要改。音频采集已在模型加载前启动(启动加速),这里
    # 只是宣告主循环即将开始消费。
    print("模型就绪。启动系统音频捕获...\n", flush=True)
    logger.log_status("ready")

    text_out = open(args.output_text, "w", encoding="utf-8") if args.output_text else None

    metrics = Metrics(args.stats)

    # segdir 模式(离线评估)无进程内采集,清空段目录等外部投喂;
    # live 模式的 audio_source.start() 已提前到模型加载之前。
    if use_segdir:
        cleanup_seg_dir()
    logger.log_status("listening")

    # macui HUD ASR chip 点击切 audio source 时发 SIGHUP (pkill -1 -f
    # whicc.py)。handler 重新读 lang_config.json 的 audio_source 键
    # + swap audio_source (停旧 source + 启动新 source + 替换
    # audio_source 引用)。SENTINEL 机制保证主循环 drain 完旧 source
    # 的残余 chunks 后,下一轮自然改读新 source 的 queue。
    #
    # 共享可变状态用 _audio_swap_lock 保护 (SIGHUP handler 在主线程
    # 之外被 Python signal 机制同步调用,但 launch_thread 的启动/停止
    # 涉及多步操作,锁住避免重入)。
    import threading as _threading
    _audio_swap_lock = _threading.Lock()

    def _swap_audio_source(new_mode: str) -> None:
        """停掉旧 audio source,启动新 source,替换 audio_source 引用。
        失败时 log error 但不崩溃 (whicc.py 继续跑 — 用户改错了能重试)。
        """
        nonlocal audio_source
        with _audio_swap_lock:
            if audio_source is None:
                return  # segdir 模式没有进程内 source,不支持热切换
            if new_mode not in ("system", "mic"):
                logger.log_status(f"unknown audio mode: {new_mode}")
                return
            try:
                old_source = audio_source
                # 旧 source 停 = 它把 SENTINEL 放进自己的 queue,主循环
                # drain 到 SENTINEL 就知道这段流结束,换读新 source 的 queue。
                old_source.stop()
                # macOS Core Audio process tap: 旧 audiotee 退出后,新
                # audiotee 启动时 macOS 26 不会重新授权 process tap
                # (TCC 静默返回 0 字节 → ~8s 后被 audio.py stall 检测
                # 杀掉)。等 1s 让 Core Audio 回收 tap 注册再起新 source。
                # SystemAudioSource (audiotee) 不需要 sleep;MicSource
                # 走 sounddevice 不涉及 TCC,无需等待。
                if old_source.label == "system":
                    time.sleep(1.0)
                # 创建新 source。mic-device 跟首次启动同 (无变更)。
                new_source = make_source(
                    mode=new_mode,
                    audiotee_path=args.audio_bin,
                    mic_device=args.mic_device,
                )
                new_source.start()
                # 替换 audio_source 引用 — 主循环每轮重新读该变量,
                # drain 完旧 queue(SENTINEL 收尾)后自然接上新 queue。
                audio_source = new_source
                logger.log_status(f"audio source → {new_mode}")
            except Exception as e:
                # 启动失败,继续用旧 source 跑 (降级)
                logger.log_status(f"audio swap to {new_mode} failed: {e}")
                # new_source.start() 失败时 audio_source 引用未替换,
                # 主循环继续读旧 source 的 queue(降级,用户可重试)

    def _sighup_audio_swap(_signum, _frame) -> None:
        """SIGHUP handler — 读 lang_config.json + swap audio source。
        同步执行 (Python signal handler 限制);swap 内部加锁防重入。
        """
        if audio_source is None:
            return  # segdir 模式(离线评估)没有进程内 source,不支持热切换
        try:
            with open("/tmp/whicc-out/lang_config.json", "r", encoding="utf-8") as f:
                cfg = json.load(f)
            new_mode = cfg.get("audio_source", args.audio_source)
            if new_mode != audio_source.label:
                # label 跟 raw mode 同名 (system/mic) 见 audio.py make_source
                # — 直接传 rawValue
                _swap_audio_source(new_mode)
        except (FileNotFoundError, json.JSONDecodeError, KeyError) as e:
            logger.log_status(f"audio swap: bad config: {e}")

    signal.signal(signal.SIGHUP, _sighup_audio_swap)

    overlap_samples = int(SAMPLE_RATE * args.overlap_sec)
    next_seg = 0            # segdir 模式的段文件游标
    samples_ingested = 0    # 已消费样本总数 → 虚拟段号 = // SAMPLE_RATE

    # 探针 ASR 缓存(soft_max/标点断句共享;submit 音频一致时复用免重转)
    sm_text = None          # 探针转录文本(strip 过)
    sm_segments = None      # 探针 segments(时间戳,find_audio_split_sec 用)
    sm_result = None        # 探针完整转录 dict,submit_chunk 复用
    sm_audio = np.array([], dtype=np.float32)  # 探针时点的音频快照,submit 复用避免后续 collected 增长导致 ASR 多识别尾巴
    sm_language = "en"      # 默认英文,probe ASR 后会被覆盖

    # 自适应 chunk 状态
    collected = []          # list[ndarray]
    collected_count = 0     # total samples
    has_speech = False
    silence_streak = 0.0
    speech_accumulated = 0.0  # 累积语音时长
    chunk_first_seg = 0     # 当前 chunk 的起始段号
    soft_max_remainder = np.array([], dtype=np.float32)  # 软最大值断句后的剩余音频
    soft_max_last_asr = 0.0   # 上次软最大值 ASR 的 monotonic 时间（0 = 未执行）

    # Partial/Final 状态
    confirmed_text = ""
    tail_buffer = ""   # 只来自已确认 final 的 tail prompt 文本
    prev_ended_with_punct = False  # 上一个 chunk 以句末标点结尾 → 下一个更快提交

    # 崩溃恢复计数
    restart_count = 0
    MAX_RESTARTS = 5

    # 静默卡死检测：None = 还没收到过任何数据,跳过卡死计时
    # (用户场景里长时间静音是正常的,启动等几秒才开始说话)。
    # 收到首段数据后变成 monotonic 时间戳,之后 30s 没新数据才退出。
    last_data_time = None

    # 保存尾部 overlap
    tail_overlap = np.array([], dtype=np.float32)

    def save_tail(samples: np.ndarray) -> np.ndarray:
        """返回 samples 末尾 overlap_samples 长度的片段；overlap_samples<=0 时返回空数组"""
        if overlap_samples <= 0:
            return np.array([], dtype=np.float32)
        return samples[-overlap_samples:] if len(samples) > overlap_samples else samples

    def build_prompt() -> tuple[str, int, str]:
        """返回 (prompt_text, tail_source_chars, prompt_hash)"""
        base = args.initial_prompt
        if args.prompt_mode == PROMPT_MODE_NONE:
            p = ""
        elif args.prompt_mode == PROMPT_MODE_TAIL:
            tail = tail_buffer[-args.prompt_tail_chars:] if tail_buffer else ""
            p = base + " " + tail if tail else base
        else:  # fixed
            p = base
        h = hashlib.md5(p.encode()).hexdigest()[:8]
        tail_src = min(len(tail_buffer), args.prompt_tail_chars) if args.prompt_mode == PROMPT_MODE_TAIL else 0
        return p, tail_src, h

    def submit_chunk(samples: np.ndarray, seg_start: int, seg_end: int,
                     submit_reason: str, speech_sec: float, trailing_silence_sec: float,
                     overlap_applied: bool = False,
                     precomputed_result: dict | None = None):
        nonlocal confirmed_text, tail_overlap, tail_buffer, resolved_model, resolved_backend, zh_streak, ja_streak, en_streak, pending_switch

        chunk_sec = len(samples) / SAMPLE_RATE
        audio_start_sec = seg_start * SEG_DURATION_SEC
        audio_end_sec = (seg_end + 1) * SEG_DURATION_SEC
        if overlap_applied:
            audio_start_sec = max(0.0, audio_start_sec - args.overlap_sec)
        buffered_sec = chunk_sec - (args.overlap_sec if overlap_applied else 0)

        # 短 chunk 直接丢弃（用 buffered_sec 排除 overlap 虚增）
        if buffered_sec < MIN_SPEECH_SEC:
            metrics.record_reject()
            logger.log_reject(seg_start, seg_end, audio_start_sec, audio_end_sec,
                              chunk_sec, time.monotonic(), prompt_mode=args.prompt_mode,
                              prompt_chars=0, reject_reason=REJECT_SHORT_CHUNK,
                              submit_reason=submit_reason,
                              buffered_sec=buffered_sec,
                              speech_sec=speech_sec,
                              trailing_silence_sec=trailing_silence_sec)
            tail_overlap = save_tail(samples)
            return

        # 阶段 1: prompt 组装(音频数组直传模型,不再写 WAV)
        try:
            t_asm_start = time.monotonic()
            prompt, tail_src, prompt_hash = build_prompt()
            t_asm_end = time.monotonic()
            asm_ms = (t_asm_end - t_asm_start) * 1000

            # 阶段 2: ASR 推理。precomputed_result = 探针对同一段音频
            # (punct_end 提交的就是探针时点的 sm_audio)已经算好的转录,
            # 直接复用 — 免掉一次整段重转,推理次数近乎减半。
            t_infer_start = time.monotonic()
            if precomputed_result is not None:
                result = precomputed_result
            else:
                result = do_transcribe(samples,
                                       language=args.language,
                                       model=resolved_model,
                                       backend=resolved_backend)
            t_infer_end = time.monotonic()
            transcribe_ms = (t_infer_end - t_infer_start) * 1000

            metrics.record(transcribe_ms, buffered_sec)

            # 立刻写 partial 事件，翻译层可提前消费
            # 但过滤掉单字幻觉（"The." "See." 等），不让它进翻译
            if result["text"] and logger._f:
                _ptxt = result["text"].strip().rstrip(".!?")
                _is_single_halluc = (
                    len(_ptxt) <= 4
                    and _ptxt.lower() in {"the", "see", "you", "a", "oh", "so", "and", "but", "is"}
                )
                if not _is_single_halluc:
                    logger.log_partial(seg_start, seg_end,
                                       audio_start_sec, audio_end_sec,
                                       result["text"])

            if args.dump_raw and result["text"]:
                print(f"[raw] {result['text']}", file=sys.stderr, flush=True)

            # 阶段 3: 后处理（过滤 + 去重 + 输出）
            t_post_start = time.monotonic()
            reject_reason, text = filter_result(result)

            if text is None:
                metrics.record_reject()
                if args.dump_filtered and reject_reason:
                    print(f"[reject:{reject_reason}] {result['text'][:60]}", file=sys.stderr, flush=True)
                logger.log_reject(seg_start, seg_end, audio_start_sec, audio_end_sec,
                                  chunk_sec, t_asm_start, args.prompt_mode, len(prompt),
                                  reject_reason or REJECT_SHORT_CHUNK,
                                  submit_reason=submit_reason,
                                  buffered_sec=buffered_sec,
                                  speech_sec=speech_sec,
                                  trailing_silence_sec=trailing_silence_sec,
                                  prompt_hash=prompt_hash,
                                  tail_source_chars=tail_src,
                                  language=result["language"],
                                  avg_logprob=result["avg_logprob"],
                                  avg_compression=result["avg_compression"],
                                  no_speech_prob=result["no_speech_prob"],
                                  text=result["text"])
                tail_overlap = save_tail(samples)
                return

            if args.dump_filtered:
                print(f"[filtered] {text}", file=sys.stderr, flush=True)

            delta = incremental_text(confirmed_text, text)
            if delta:
                if text_out:
                    text_out.write(delta + "\n")
                    text_out.flush()

            # 更新 tail_buffer（只来自已确认 final）
            confirmed_text = text
            tail_buffer = text[-args.prompt_tail_chars:]
            # 标点感知：下个 chunk 更快提交
            prev_ended_with_punct = text.rstrip()[-1:] in "。！？.!?"

            # 语言感知模型切换（观察区 + 连续计数 + 异步加载）
            qwen_lang = _detect_qwen_lang(text)
            ratio = _cjk_ratio(text)
            zh_streak = zh_streak + 1 if qwen_lang == "zh" and ratio >= CJK_OBSERVE_LOW else 0
            ja_streak = ja_streak + 1 if qwen_lang == "ja" else 0
            en_streak = en_streak + 1 if qwen_lang is None else 0
            cjk_streak = max(zh_streak, ja_streak)  # 中日文共用切换阈值

            if pending_switch:
                # 异步加载中，检查是否完成
                if switch_ready.is_set():
                    if pending_switch == "to_qwen3":
                        if not args.dual_model:
                            _unload_nemotron()
                            import gc; gc.collect()
                        resolved_model = qwen3_path
                        resolved_backend = "qwen3"
                        logger.log_status("已切换到 Qwen3 ASR", status_color="green")
                    elif pending_switch == "to_nemotron":
                        if not args.dual_model:
                            _unload_qwen3()
                            import gc; gc.collect()
                        resolved_model = nemotron_model
                        resolved_backend = "nemotron"
                        logger.log_status("已切换回 Nemotron ASR", status_color="green")
                    print(f"[lang-switch] 模型加载完成，已切换", file=sys.stderr, flush=True)
                    pending_switch = None
                    switch_ready.clear()
                    zh_streak = 0
                    ja_streak = 0
                    en_streak = 0

            elif resolved_backend != "qwen3" and ja_streak >= 2:
                # 日文：连续 2 句检测到假名才切换
                print(f"[lang-switch] 检测到日文 (连续{ja_streak}句)，切换到 Qwen3", file=sys.stderr, flush=True)
                if not args.dual_model:
                    _unload_nemotron()
                    import gc; gc.collect()
                    _get_qwen3_model(qwen3_path)
                resolved_model = qwen3_path
                resolved_backend = "qwen3"
                logger.log_status("检测到日文，已切换到 Qwen3", status_color="green")
                ja_streak = 0
                en_streak = 0

            elif resolved_backend != "qwen3" and zh_streak >= 2:
                # 中文切换：连续 2 句 CJK >= 0.3 才触发
                if ratio >= CJK_SWITCH_HIGH:
                    # 高置信度，直接切换（双模型秒切 / 单模型同步加载）
                    print(f"[lang-switch] 高置信中文 ({ratio:.0%})，切换到 Qwen3", file=sys.stderr, flush=True)
                    # 先发橙色开始事件
                    logger.log_status("检测到中文，正在加载 Qwen3...", status_color="orange")
                    if not args.dual_model:
                        _unload_nemotron()
                        import gc; gc.collect()
                        _get_qwen3_model(qwen3_path)
                        # Warmup：避免第一次推理编译 Metal kernel 卡 30-60s
                        try:
                            _warmup_model(qwen3_path, "qwen3")
                        except Exception as e:
                            print(f"[lang-switch] warmup 失败: {e}", file=sys.stderr, flush=True)
                    resolved_model = qwen3_path
                    resolved_backend = "qwen3"
                    logger.log_status("已切换到 Qwen3 ASR", status_color="green")
                    zh_streak = 0
                    en_streak = 0
                elif not pending_switch:
                    # 观察区，异步加载
                    print(f"[lang-switch] 观察区中文 ({ratio:.0%})，异步加载 Qwen3", file=sys.stderr, flush=True)
                    logger.log_status("检测到中文，正在加载 Qwen3...", status_color="orange")
                    pending_switch = "to_qwen3"
                    switch_ready.clear()
                    t = threading.Thread(target=_async_load_model,
                                         args=("qwen3", qwen3_path, switch_ready), daemon=True)
                    t.start()

            elif resolved_backend == "qwen3" and en_streak >= 3:
                # 连续 3 句非中日文，切回 Nemotron
                if args.dual_model:
                    print(f"[lang-switch] 检测到英文，切换回 Nemotron", file=sys.stderr, flush=True)
                    resolved_model = nemotron_model
                    resolved_backend = "nemotron"
                    logger.log_status("已切换回 Nemotron ASR", status_color="green")
                else:
                    print(f"[lang-switch] 检测到英文，异步加载 Nemotron", file=sys.stderr, flush=True)
                    logger.log_status("检测到英文，正在加载 Nemotron...", status_color="orange")
                    pending_switch = "to_nemotron"
                    switch_ready.clear()
                    t = threading.Thread(target=_async_load_model,
                                         args=("nemotron", nemotron_model, switch_ready), daemon=True)
                    t.start()

            t_post_end = time.monotonic()
            postproc_ms = (t_post_end - t_post_start) * 1000

            logger.log_final(seg_start, seg_end, audio_start_sec, audio_end_sec,
                             chunk_sec, t_asm_start, t_post_end, transcribe_ms,
                             args.prompt_mode, len(prompt), text,
                             submit_reason=submit_reason,
                             buffered_sec=buffered_sec,
                             speech_sec=speech_sec,
                             trailing_silence_sec=trailing_silence_sec,
                             prompt_hash=prompt_hash,
                             tail_source_chars=tail_src,
                             asm_ms=asm_ms,
                             postproc_ms=postproc_ms,
                             language=result["language"],
                             avg_logprob=result["avg_logprob"],
                             avg_compression=result["avg_compression"],
                             no_speech_prob=result["no_speech_prob"])

        except Exception as e:
            print(f"[error] submit_chunk 异常，跳过当前 chunk: {e}", file=sys.stderr, flush=True)
            logger.write({
                "event_type": "error",
                "seg_start": seg_start,
                "seg_end": seg_end,
                "audio_start_sec": round(audio_start_sec, 3),
                "audio_end_sec": round(audio_end_sec, 3),
                "chunk_sec": round(chunk_sec, 3),
                "submit_reason": submit_reason,
                "speech_sec": round(speech_sec, 3),
                "trailing_silence_sec": round(trailing_silence_sec, 3),
                "prompt_mode": args.prompt_mode,
                "error": str(e),
            })

        # 保留 overlap（正常路径和异常路径都执行）
        tail_overlap = save_tail(samples)

    try:
        while True:
            # 音频源的崩溃恢复由 audio.py 的 SystemAudioSource 内部
            # supervisor 线程处理（5s stall 自动重启 audiotee）。whicc.py
            # 只消费数据:live 模式读 source.queue,segdir 模式轮询段文件。
            # SIGINT/SIGTERM 时 audio_source.stop() 会优雅退出。
            #
            # 保留 30s 长 stall 的总超时,防止 audio 源自己挂了重启又
            # 不成功时,whicc.py 无限循环。
            now = time.monotonic()
            # 收到首段数据后才开始计 30s;启动期静音不退出。
            if last_data_time is not None and now - last_data_time > 30.0:
                print(f"\n[error] 音频源 30s 无数据,whicc.py 退出。"
                      "检查 audio.py 错误日志或 audiotee 二进制。",
                      file=sys.stderr, flush=True)
                break

            # 读取新音频:
            #  - live(system/mic): 阻塞至多 POLL_INTERVAL 等内存 queue 的
            #    chunks,到达即处理(采集回调粒度 ~0.1s,无磁盘往返)
            #  - segdir: 0.15s 轮询 SEG_DIR 段文件(离线评估协议)
            if use_segdir:
                time.sleep(POLL_INTERVAL)
                raw_segs, next_seg = read_segments(next_seg)
                new_arrays = []
                for data in raw_segs:
                    try:
                        new_arrays.append(
                            np.frombuffer(data, dtype=np.float32).copy())
                    except (ValueError, BufferError) as e:
                        print(f"[warn] 损坏段文件已跳过: {e}",
                              file=sys.stderr, flush=True)
            else:
                new_arrays = drain_audio_queue(audio_source.queue,
                                               POLL_INTERVAL)

            if not new_arrays:
                continue
            last_data_time = time.monotonic()  # 收到新数据，重置卡死计时器

            # 逐 chunk 处理，精确维护 chunk 边界
            # 软最大值剩余音频：作为当前 chunk 的起始部分（不设 overlap，它是直接延续）
            if len(soft_max_remainder) > 0:
                collected.insert(0, soft_max_remainder)
                collected_count += len(soft_max_remainder)
                soft_max_remainder = np.array([], dtype=np.float32)

            batch_started = False
            for samples in new_arrays:
                # 虚拟段号 = 已消费整秒数(1 段 ≡ 1 秒),与旧文件段号语义一致
                # — translate_stream._source_key 和日志对齐依赖 seg_start/
                # seg_end。segdir 模式每段恰 1s,虚拟号等于文件段号。
                # 新 chunk 起始段号（仅在 collected 为空时更新，remainder 不影响）
                if not collected and not batch_started:
                    chunk_first_seg = samples_ingested // SAMPLE_RATE
                batch_started = True
                samples_ingested += len(samples)

                collected.append(samples)
                collected_count += len(samples)

                # 能量检测（最新 20ms 窗口）
                window = samples[-int(SAMPLE_RATE * 0.02):]
                rms = np.sqrt(np.mean(window ** 2)) if len(window) > 0 else 0

                if rms > args.silence_threshold:
                    has_speech = True
                    silence_streak = 0
                    speech_accumulated += len(samples) / SAMPLE_RATE
                else:
                    silence_streak += len(samples) / SAMPLE_RATE

            chunk_sec = collected_count / SAMPLE_RATE
            seg_end = samples_ingested // SAMPLE_RATE  # 当前虚拟段号(累计秒)

            # ---- 探针 ASR: 累积够 MIN_CHUNK_SEC (2s) 就跑,持续刷新 sm_text ----
            # 触发器 (punct_end) 看 sm_text 是否包含完整句末标点 — 当前 ASR 看到的
            # 真实文本,而不是"上一段 final 的标点"。这样能避免切半句话。
            # 软最大值切割在下面单独判断,共用 sm_text 缓存不重复跑推理。
            if chunk_sec >= MIN_CHUNK_SEC and has_speech:
                need_asr = sm_text is None or (time.monotonic() - soft_max_last_asr) >= SOFT_MAX_ASR_COOLDOWN
                if need_asr:
                    all_sm = np.concatenate(collected)
                    sm_audio = all_sm.copy()
                    try:
                        # 数组直传 — 探针每 0.6s 跑一次,之前每次都
                        # save_wav 落盘再让模型读回,现在零磁盘往返。
                        result_sm = do_transcribe(all_sm,
                                                  language=args.language,
                                                  model=resolved_model,
                                                  backend=resolved_backend)
                        sm_text = result_sm.get("text", "").strip()
                        sm_segments = result_sm.get("segments")
                        sm_result = result_sm  # 完整 dict,submit 音频一致时复用
                        # ASR 返回的 language (e.g. "zh" / "en") 用于分语言阈值
                        sm_language = result_sm.get("language", "en") or "en"
                        # Nemotron 返回 "zh" / "en" / "zh-CN" 等,Qwen3 返回 ["zh"] 列表
                        if isinstance(sm_language, list):
                            sm_language = sm_language[0] if sm_language else "en"
                        # 规范化: "zh-CN" / "zh-Hans" → "zh"
                        sm_language = sm_language.split("-")[0].lower()
                        soft_max_last_asr = time.monotonic()
                        if not sm_text:
                            sm_text = None
                            sm_result = None
                            sm_audio = np.array([], dtype=np.float32)
                    except Exception as e:
                        print(f"[probe-asr] ASR 异常: {e}", file=sys.stderr, flush=True)
                        sm_text = None
                        sm_result = None
                        sm_audio = np.array([], dtype=np.float32)

            # ---- 标点感知断句: ASR 看到完整句立刻在标点位置切 ----
            # 与 soft_max 区别: 不要求 chunk_sec >= SOFT_MAX_SEC。
            # 只要 ASR 当前看到的文本 (sm_text) 以强句末标点结尾 + 累积够
            # 阈值,就在标点的音频位置切,而不是切到 chunk 末尾 — 否则 submit_chunk
            # 重跑 ASR 会被 overlap 多听的音频污染,产生 "Human centered... right?
            # People are" 这种 mid-sentence 尾巴。用 find_audio_split_sec 的
            # segments 时间戳精确定位标点 → submit 前半,剩余音频 (标点后) 作为新
            # chunk 起始 (跟 soft_max 一样)。
            #
            # 分语言阈值 (PUNCT_END_MIN_CHUNK_SEC_EN=3 / _ZH=5),中文需要更多上下文。
            # 字符数校验 (MIN_CHARS_BEFORE_PUNCT_*): 中文 12 字以上,英文 8 字以上。
            _cur_lang = sm_language
            _min_chunk_for_punct = PUNCT_END_MIN_CHUNK_SEC_ZH if _cur_lang.startswith("zh") else PUNCT_END_MIN_CHUNK_SEC_EN
            _min_chars_before_punct = MIN_CHARS_BEFORE_PUNCT_ZH if _cur_lang.startswith("zh") else MIN_CHARS_BEFORE_PUNCT_EN
            _stripped_sm = sm_text.rstrip() if sm_text else ""
            _chars_before_punct = len(_stripped_sm) - 1 if _stripped_sm else 0
            if (chunk_sec >= _min_chunk_for_punct and has_speech and sm_text
                    and _stripped_sm[-1:] in STRONG_END_PUNCT
                    and _chars_before_punct >= _min_chars_before_punct):
                split_sec = find_audio_split_sec(
                    sm_text, chunk_sec, sm_segments,
                    min_char_pos=0)  # 任意位置都允许,标点已经是强句末
                # 校验: 切点不能太短 (< 0.5s, 字幕太碎) 也不能太靠近结尾
                # (>= chunk_sec - 0.3s, 剩余音频几乎为空,失去切的意义)
                if split_sec > 0 and 0.5 <= split_sec <= chunk_sec - 0.3:
                    all_sm = np.concatenate(collected)
                    split_pos = int(split_sec * SAMPLE_RATE)
                    first_part = all_sm[:split_pos]
                    remainder_audio = all_sm[split_pos:]
                    print(f"[punct-split] 标点位置切 @{split_sec:.1f}s/{chunk_sec:.1f}s: "
                          f"{sm_text[:50]}... | 剩余 {len(remainder_audio)/SAMPLE_RATE:.1f}s",
                          file=sys.stderr, flush=True)
                    submit_chunk(first_part, chunk_first_seg, seg_end,
                                 submit_reason="punct_split",
                                 speech_sec=speech_accumulated,
                                 trailing_silence_sec=silence_streak,
                                 overlap_applied=False)  # 不加 overlap: 已经精确切到标点位置
                    soft_max_remainder = remainder_audio
                    collected = []
                    collected_count = 0
                    has_speech = False
                    silence_streak = 0
                    speech_accumulated = 0
                    soft_max_last_asr = 0.0
                    sm_text = None
                    sm_result = None
                    sm_audio = np.array([], dtype=np.float32)
                    should_submit = False
                    should_discard = False
                    continue
                # 否则 split 不理想,fall through 到下面的 soft_max / punct_end 兜底

            # ---- 软最大值断句: 累积够 SOFT_MAX_SEC (4.6s) 才在标点处切 ----
            # 共用上面探针的 sm_text/sm_segments 缓存,不重复跑推理。
            # 找到合适的标点 → 在标点位置切 (前半提交 final, 后半作为新 chunk 继续)。
            if chunk_sec >= SOFT_MAX_SEC and has_speech and sm_text:
                split_sec = find_audio_split_sec(
                    sm_text, chunk_sec, sm_segments,
                    min_char_pos=SOFT_MAX_MIN_CHARS)
                split_label = "整句"
                if split_sec == 0 and len(sm_text) >= SOFT_MAX_MIN_CHARS:
                    split_sec = find_audio_split_sec(
                        sm_text, chunk_sec, sm_segments,
                        punct_set=SENTENCE_END_PUNCT | MID_PUNCT,
                        min_char_pos=SOFT_MAX_MIN_CHARS)
                    split_label = "中间标点"
                min_split = 1.5 if split_label == "中间标点" else 0.5
                max_remainder = 0.5 if split_label == "中间标点" else 0.3
                if split_sec == 0 or split_sec <= min_split or split_sec > chunk_sec - max_remainder:
                    if split_sec > 0:
                        print(f"[soft-max] 标点位置不佳 ({split_sec:.1f}s/{chunk_sec:.1f}s)，继续积累",
                              file=sys.stderr, flush=True)
                else:
                    all_sm = np.concatenate(collected)
                    split_pos = int(split_sec * SAMPLE_RATE)
                    first_part = all_sm[:split_pos]
                    remainder_audio = all_sm[split_pos:]
                    is_full = split_label == "整句"
                    reason = "soft_max" if is_full else "soft_max_split"
                    print(f"[soft-max] {split_label}断句 @{split_sec:.1f}s: "
                          f"{sm_text[:50]} | 剩余 {len(remainder_audio)/SAMPLE_RATE:.1f}s",
                          file=sys.stderr, flush=True)
                    submit_chunk(first_part, chunk_first_seg, seg_end,
                                 submit_reason=reason,
                                 speech_sec=speech_accumulated,
                                 trailing_silence_sec=silence_streak,
                                 overlap_applied=is_full and len(tail_overlap) > 0)
                    soft_max_remainder = remainder_audio if not is_full else np.array([], dtype=np.float32)
                    collected = []
                    collected_count = 0
                    has_speech = False
                    silence_streak = 0
                    speech_accumulated = 0
                    soft_max_last_asr = 0.0
                    sm_text = None
                    sm_result = None
                    sm_audio = np.array([], dtype=np.float32)
                    should_submit = False
                    should_discard = False
                    continue

            # ---- Normal 提交判断 ----
            should_submit = False
            should_discard = False
            submit_reason = ""

            # 标点感知断句：上一句以句末标点结尾时，更快提交
            effective_silence = PUNCT_SUBMIT_SEC if prev_ended_with_punct else args.silence_submit_sec

            # 新触发器: 当前 ASR 看到的文本 (sm_text) 以强句末标点结尾 + 累积够阈值 → 切。
            # 关键: 用 sm_text 而不是"上一段 final 的标点",避免 ASR streaming 提前标点切碎。
            # - 分语言阈值: 英文 3.0s,中文 5.0s (中文 ASR 容易幻觉句末标点,需要更多上下文)
            # - 中文额外字符数校验: 标点前 >= 12 字才算完整句 (避免 "美联。" 3 字截断)
            # - STRONG_END_PUNCT: 排除 ,;: 等中间标点,只在强句末标点切
            # - overlap_applied=False: 不要在 submit 时叠加 tail_overlap。
            #   tail_overlap 是上一段 final 末尾的 0.3s,提交时叠上去会让 ASR
            #   多听一段音频 → 可能把 sm_text 之后的 "I have to" / "People are"
            #   等续接内容拉进来,产生 mid-sentence 结尾。
            #   probe ASR 用的是当前 chunk 音频,submit 不加 overlap 就跟 probe 看到的音频范围一致。
            punct_end_submit = False
            # 根据语言选阈值
            _cur_lang = sm_language
            _min_chunk_for_punct = PUNCT_END_MIN_CHUNK_SEC_ZH if _cur_lang.startswith("zh") else PUNCT_END_MIN_CHUNK_SEC_EN
            _min_chars_before_punct = MIN_CHARS_BEFORE_PUNCT_ZH if _cur_lang.startswith("zh") else MIN_CHARS_BEFORE_PUNCT_EN
            if (has_speech and chunk_sec >= _min_chunk_for_punct and sm_text
                    and sm_text.rstrip()[-1:] in STRONG_END_PUNCT):
                # 字符数校验: 标点前的字符数 (去掉尾部空白后)。中文常见 "。" 前有
                # 短句 (5-8 字),如果是 3 字就强烈疑似 ASR 幻觉 (e.g. "美联。")。
                _stripped = sm_text.rstrip()
                _chars_before_punct = len(_stripped) - 1  # 去掉末尾的标点
                if _chars_before_punct >= _min_chars_before_punct:
                    should_submit = True
                    submit_reason = "punct_end"
                    punct_end_submit = True
            elif has_speech and silence_streak >= effective_silence:
                should_submit = True
                submit_reason = "silence"
            elif chunk_sec >= args.max_chunk_sec:
                if has_speech:
                    should_submit = True
                    submit_reason = "max_chunk"
                else:
                    should_discard = True

            if should_submit:
                # punct_end 路径: 用探针时点的 sm_audio (跟 probe ASR 完全相同的音频),
                # 而不是当前 collected (collected 累积到 submit 时多了 0.3s,
                # ASR 会多识别出 "...right? People are" 这种 mid-sentence 尾巴)
                # 提交音频与探针一致时把探针转录一并传下去,submit_chunk 免重转。
                if punct_end_submit and len(sm_audio) > 0:
                    all_samples = sm_audio
                    overlap_applied = False
                    reuse_result = sm_result
                else:
                    all_samples = np.concatenate(collected) if collected else np.array([], dtype=np.float32)
                    reuse_result = None
                    if punct_end_submit:
                        overlap_applied = False
                    else:
                        overlap_applied = len(tail_overlap) > 0 and len(all_samples) > 0
                        if overlap_applied:
                            all_samples = np.concatenate([tail_overlap, all_samples])
                        elif sm_result is not None and len(sm_audio) == len(all_samples):
                            # silence/max_chunk 提交的音频与探针时点完全一致
                            # (collected 只尾部 append,等长 ⇒ 同一段) → 复用
                            reuse_result = sm_result
                cur_speech = speech_accumulated
                cur_trailing = silence_streak
                collected = []
                collected_count = 0
                has_speech = False
                silence_streak = 0
                speech_accumulated = 0
                sm_text = None
                sm_result = None
                sm_audio = np.array([], dtype=np.float32)
                submit_chunk(all_samples, chunk_first_seg, seg_end,
                             submit_reason=submit_reason,
                             speech_sec=cur_speech,
                             trailing_silence_sec=cur_trailing,
                             overlap_applied=overlap_applied,
                             precomputed_result=reuse_result)

            elif should_discard:
                # 纯静音，丢弃但保留尾部 overlap
                if collected:
                    last = collected[-1]
                    tail_overlap = save_tail(last)
                collected = []
                collected_count = 0
                has_speech = False
                silence_streak = 0
                speech_accumulated = 0

    except KeyboardInterrupt:
        print("\n退出。", flush=True)
    finally:
        metrics.report()
        logger.close()
        if text_out:
            text_out.close()
        # 关闭音频源——AudioSource.stop() 会把 audiotee 子进程 /
        # sounddevice stream 收掉。
        if audio_source is not None:
            try:
                audio_source.stop()
            except Exception as e:  # noqa: BLE001
                print(f"[audio] stop() 异常: {e}", file=sys.stderr)
        if use_segdir:
            cleanup_seg_dir()

if __name__ == "__main__":
    main()
