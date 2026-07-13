"""Glossary JSON store — shared contract for macui GlossaryState + refresher.

Wire format (glossary.json)::

    {
      "zh2en": {"中文术语": "English term"},
      "en2zh": {"English term": "中文术语"},
      "_meta": {
        "中文术语": {
          "source": "manual|hermes|web|lm",
          "added": "YYYY-MM-DD HH:MM:SS",
          "last_used": "...",
          "hits": 0
        }
      }
    }

macui 手动词库写入必须与此一致；pytest 锁住语义，避免 UI 能点但落盘格式错。
"""

from __future__ import annotations

import json
import os
import tempfile
from datetime import datetime
from typing import Any


def empty_glossary() -> dict[str, Any]:
    """返回空词库骨架。"""
    return {"zh2en": {}, "en2zh": {}, "_meta": {}}


def now_str() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def normalize_glossary(data: Any) -> dict[str, Any]:
    """把任意加载结果规范成可写结构。"""
    if not isinstance(data, dict):
        return empty_glossary()
    out = empty_glossary()
    zh2en = data.get("zh2en")
    en2zh = data.get("en2zh")
    meta = data.get("_meta")
    if isinstance(zh2en, dict):
        out["zh2en"] = {str(k): str(v) for k, v in zh2en.items() if k and v}
    if isinstance(en2zh, dict):
        out["en2zh"] = {str(k): str(v) for k, v in en2zh.items() if k and v}
    if isinstance(meta, dict):
        out["_meta"] = meta
    return out


def add_entry(
    glossary: dict[str, Any],
    zh: str,
    en: str,
    *,
    source: str = "manual",
    ts: str | None = None,
) -> dict[str, Any]:
    """添加一条中英对照术语。zh/en 去空白后任一侧为空则原样返回。

    若中文键已存在则拒绝覆盖（与 macui GlossaryState.addEntry 一致）。
    """
    zh = (zh or "").strip()
    en = (en or "").strip()
    g = normalize_glossary(glossary)
    if not zh or not en:
        return g
    zh2en: dict[str, str] = dict(g["zh2en"])
    if zh in zh2en:
        return g
    en2zh: dict[str, str] = dict(g["en2zh"])
    meta: dict[str, Any] = dict(g["_meta"])
    stamp = ts or now_str()
    zh2en[zh] = en
    en2zh[en] = zh
    meta[zh] = {
        "source": source,
        "added": stamp,
        "last_used": stamp,
        "hits": 0,
    }
    return {"zh2en": zh2en, "en2zh": en2zh, "_meta": meta}


def delete_entry(glossary: dict[str, Any], zh: str) -> dict[str, Any]:
    """按中文键删除术语，并同步清掉 en2zh / _meta。"""
    zh = (zh or "").strip()
    g = normalize_glossary(glossary)
    if not zh:
        return g
    zh2en: dict[str, str] = dict(g["zh2en"])
    en2zh: dict[str, str] = dict(g["en2zh"])
    meta: dict[str, Any] = dict(g["_meta"])
    en = zh2en.pop(zh, None)
    if en is not None:
        en2zh.pop(en, None)
    meta.pop(zh, None)
    return {"zh2en": zh2en, "en2zh": en2zh, "_meta": meta}


def update_entry(
    glossary: dict[str, Any],
    old_zh: str,
    new_zh: str,
    new_en: str,
    *,
    source: str = "manual",
    ts: str | None = None,
) -> dict[str, Any]:
    """先删旧键再添加新键（与 macui updateEntry 一致）。"""
    g = delete_entry(glossary, old_zh)
    return add_entry(g, new_zh, new_en, source=source, ts=ts)


def load_glossary(path: str) -> dict[str, Any]:
    """从磁盘读取；文件不存在或损坏时返回空词库。"""
    try:
        with open(path, "r", encoding="utf-8") as f:
            return normalize_glossary(json.load(f))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return empty_glossary()


def save_glossary(path: str, glossary: dict[str, Any]) -> None:
    """原子写入 glossary.json；自动创建父目录。

    打包进 /Applications 后不能往 .app/Contents/Resources 写，
    调用方应把 path 指到可写目录（如 Application Support）。
    """
    g = normalize_glossary(glossary)
    parent = os.path.dirname(os.path.abspath(path))
    if parent:
        os.makedirs(parent, exist_ok=True)
    data = json.dumps(g, ensure_ascii=False, indent=2, sort_keys=True)
    fd, tmp = tempfile.mkstemp(prefix=".glossary-", suffix=".tmp", dir=parent or None)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(data)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def add_entry_to_file(path: str, zh: str, en: str, *, source: str = "manual") -> dict[str, Any]:
    """读-改-写便捷接口，供 CLI / 测试模拟 macui 添加术语。"""
    g = add_entry(load_glossary(path), zh, en, source=source)
    save_glossary(path, g)
    return g
