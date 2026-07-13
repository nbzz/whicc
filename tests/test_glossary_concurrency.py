"""词库并发安全与 manual 术语保护 — 直接测生产实现。

覆盖两条 P1 与落盘语义：
  1. glossary_refresher.cleanup_glossary 不得删除 source=manual 的术语
     （过期与无效字符清理均豁免）。
  2. 多进程覆盖：refresher merge_added_into_glossary 与
     translate_stream._flush_glossary_meta 都必须以磁盘最新版为底合并，
     不能用旧内存快照整份覆盖。
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "src"
sys.path.insert(0, str(ROOT))

import glossary_refresher as gr  # noqa: E402
import translate_stream as ts  # noqa: E402


def _write_glossary(path: Path, glossary: dict) -> None:
    path.write_text(json.dumps(glossary, ensure_ascii=False, indent=2),
                    encoding="utf-8")


def _read_glossary(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def _entry(source: str, *, hits: int = 0, last_used: str | None = None) -> dict:
    stamp = last_used or time.strftime("%Y-%m-%d %H:%M:%S")
    return {"source": source, "added": stamp, "last_used": stamp, "hits": hits}


OLD = "2000-01-01 00:00:00"  # 远超所有过期阈值


# ── P1: manual 术语不被自动清理 ──────────────────────────────────────────────


def test_cleanup_expires_lm_but_keeps_manual():
    g = {
        "zh2en": {"手工词": "Manual term", "机器词": "LM term"},
        "en2zh": {"Manual term": "手工词", "LM term": "机器词"},
        "_meta": {
            "手工词": _entry("manual", last_used=OLD),
            "机器词": _entry("lm", last_used=OLD),
        },
    }
    removed = gr.cleanup_glossary(g)
    assert "机器词" in removed
    assert "手工词" not in removed
    assert g["zh2en"] == {"手工词": "Manual term"}
    assert g["en2zh"] == {"Manual term": "手工词"}
    assert "手工词" in g["_meta"]


def test_cleanup_invalid_char_rule_exempts_manual():
    """用户手工加的『含拉丁字符 zh 键 / 纯中文 en 值』不能当脏数据删掉。"""
    g = {
        "zh2en": {"GPU集群": "GPU cluster", "x脏数据x": "dirty"},
        "en2zh": {"GPU cluster": "GPU集群", "dirty": "x脏数据x"},
        "_meta": {
            "GPU集群": _entry("manual"),
            "x脏数据x": _entry("lm"),
        },
    }
    removed = gr.cleanup_glossary(g)
    assert "GPU集群" in g["zh2en"]
    assert "GPU cluster" in g["en2zh"]
    assert "x脏数据x" in removed


def test_cleanup_unknown_source_still_expires():
    g = {
        "zh2en": {"未知词": "Unknown"},
        "en2zh": {"Unknown": "未知词"},
        "_meta": {"未知词": _entry("unknown", last_used=OLD)},
    }
    removed = gr.cleanup_glossary(g)
    assert "未知词" in removed


# ── P1: refresher 合并式写入，不覆盖并发修改 ─────────────────────────────────


def test_merge_added_preserves_concurrent_manual_add(tmp_path, monkeypatch):
    path = tmp_path / "glossary.json"
    monkeypatch.setattr(gr, "GLOSSARY_PATH", str(path))

    # 模拟 run_once 长调用期间，macui 手动添加了「用户词」
    _write_glossary(path, {
        "zh2en": {"用户词": "User term"},
        "en2zh": {"User term": "用户词"},
        "_meta": {"用户词": _entry("manual")},
    })

    now = gr._now_ts()
    gr.merge_added_into_glossary({"新学词": ("Learned term", "hermes")}, now)

    saved = _read_glossary(path)
    assert saved["zh2en"]["用户词"] == "User term", "并发手动添加被覆盖丢失"
    assert saved["zh2en"]["新学词"] == "Learned term"
    assert saved["_meta"]["用户词"]["source"] == "manual"
    assert saved["_meta"]["新学词"]["source"] == "hermes"


def test_merge_added_does_not_resurrect_deleted_terms(tmp_path, monkeypatch):
    path = tmp_path / "glossary.json"
    monkeypatch.setattr(gr, "GLOSSARY_PATH", str(path))

    # run_once 加载时「旧词」还在；期间用户删掉了它 → 磁盘上已无
    _write_glossary(path, {"zh2en": {}, "en2zh": {}, "_meta": {}})

    gr.merge_added_into_glossary({"新词": ("New", "hermes")}, gr._now_ts())

    saved = _read_glossary(path)
    assert "旧词" not in saved["zh2en"]
    assert saved["zh2en"] == {"新词": "New"}


def test_merge_added_keeps_existing_zh_key(tmp_path, monkeypatch):
    """磁盘已有同名 zh 键（用户手工版）时，refresher 不得覆盖译法。"""
    path = tmp_path / "glossary.json"
    monkeypatch.setattr(gr, "GLOSSARY_PATH", str(path))
    _write_glossary(path, {
        "zh2en": {"同名词": "User version"},
        "en2zh": {"User version": "同名词"},
        "_meta": {"同名词": _entry("manual")},
    })

    gr.merge_added_into_glossary({"同名词": ("Hermes version", "hermes")}, gr._now_ts())

    saved = _read_glossary(path)
    assert saved["zh2en"]["同名词"] == "User version"
    assert saved["_meta"]["同名词"]["source"] == "manual"


def test_save_glossary_atomic_no_tmp_left(tmp_path, monkeypatch):
    path = tmp_path / "glossary.json"
    monkeypatch.setattr(gr, "GLOSSARY_PATH", str(path))
    gr.save_glossary({"zh2en": {"词": "Term"}, "en2zh": {"Term": "词"}, "_meta": {}})
    assert _read_glossary(path)["zh2en"] == {"词": "Term"}
    assert not (tmp_path / "glossary.json.tmp").exists()


# ── P1: translate_stream 命中刷盘不整份覆盖 ─────────────────────────────────


def test_flush_hits_merges_into_fresh_disk_copy(tmp_path):
    path = tmp_path / "glossary.json"
    _write_glossary(path, {
        "zh2en": {"手工词": "Manual term", "后来加的": "Added later"},
        "en2zh": {"Manual term": "手工词", "Added later": "后来加的"},
        "_meta": {
            "手工词": _entry("manual", hits=3),
            "后来加的": _entry("manual"),
        },
    })

    ts._glossary_hits_buffer.clear()
    ts._glossary_hits_buffer["手工词"] = 2
    ts._flush_glossary_meta(str(path))

    saved = _read_glossary(path)
    # 命中计数累加，而不是回写内存旧快照
    assert saved["_meta"]["手工词"]["hits"] == 5
    assert saved["_meta"]["手工词"]["source"] == "manual"
    # 刷盘期间已存在的其他词条 / _meta 不丢
    assert saved["zh2en"]["后来加的"] == "Added later"
    assert "后来加的" in saved["_meta"]
    # 刷成功后 buffer 清空
    assert ts._glossary_hits_buffer == {}


def test_flush_hits_noop_when_buffer_empty(tmp_path):
    path = tmp_path / "glossary.json"
    _write_glossary(path, {"zh2en": {}, "en2zh": {}, "_meta": {}})
    before = path.read_text(encoding="utf-8")
    ts._glossary_hits_buffer.clear()
    ts._flush_glossary_meta(str(path))
    assert path.read_text(encoding="utf-8") == before


def test_flush_hits_survives_missing_file(tmp_path):
    """词库文件尚不存在时刷盘不能崩，创建含命中记录的新文件。"""
    path = tmp_path / "glossary.json"
    ts._glossary_hits_buffer.clear()
    ts._glossary_hits_buffer["某词"] = 1
    ts._flush_glossary_meta(str(path))
    saved = _read_glossary(path)
    assert saved["_meta"]["某词"]["hits"] == 1
