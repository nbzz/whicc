"""glossary_store 契约测试 — 锁住 macui 手动词库落盘语义。"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1] / "src"
sys.path.insert(0, str(ROOT))

import glossary_store as gs  # noqa: E402


def test_empty_glossary_shape():
    g = gs.empty_glossary()
    assert g == {"zh2en": {}, "en2zh": {}, "_meta": {}}


def test_add_entry_writes_both_directions_and_meta():
    g = gs.add_entry({}, "注意力机制", "Attention", source="manual", ts="2026-07-13 12:00:00")
    assert g["zh2en"]["注意力机制"] == "Attention"
    assert g["en2zh"]["Attention"] == "注意力机制"
    meta = g["_meta"]["注意力机制"]
    assert meta["source"] == "manual"
    assert meta["added"] == "2026-07-13 12:00:00"
    assert meta["hits"] == 0


def test_add_entry_rejects_blank_sides():
    base = gs.add_entry({}, "已有", "Existing", ts="t0")
    assert gs.add_entry(base, "  ", "X") == base
    assert gs.add_entry(base, "Y", "") == base


def test_add_entry_does_not_overwrite_existing_zh():
    g = gs.add_entry({}, "模型", "Model", ts="t0")
    g2 = gs.add_entry(g, "模型", "Other", ts="t1")
    assert g2["zh2en"]["模型"] == "Model"
    assert "Other" not in g2["en2zh"]


def test_delete_entry_removes_en2zh_and_meta():
    g = gs.add_entry({}, "解码器", "Decoder", ts="t0")
    g = gs.delete_entry(g, "解码器")
    assert g["zh2en"] == {}
    assert g["en2zh"] == {}
    assert g["_meta"] == {}


def test_update_entry_replaces_key():
    g = gs.add_entry({}, "旧词", "Old", ts="t0")
    g = gs.update_entry(g, "旧词", "新词", "New", ts="t1")
    assert "旧词" not in g["zh2en"]
    assert g["zh2en"]["新词"] == "New"
    assert g["en2zh"]["New"] == "新词"
    assert "Old" not in g["en2zh"]


def test_save_and_load_roundtrip(tmp_path: Path):
    path = tmp_path / "nested" / "glossary.json"
    g = gs.add_entry({}, "量子纠缠", "Quantum entanglement", ts="t0")
    gs.save_glossary(str(path), g)
    assert path.is_file()
    loaded = gs.load_glossary(str(path))
    assert loaded["zh2en"]["量子纠缠"] == "Quantum entanglement"
    assert loaded["en2zh"]["Quantum entanglement"] == "量子纠缠"


def test_add_entry_to_file_simulates_macui_manual_add(tmp_path: Path):
    """模拟设置页点「添加术语」后的落盘结果。"""
    path = tmp_path / "glossary.json"
    gs.add_entry_to_file(str(path), "卷积神经网络", "CNN")
    raw = json.loads(path.read_text(encoding="utf-8"))
    assert raw["zh2en"]["卷积神经网络"] == "CNN"
    assert raw["en2zh"]["CNN"] == "卷积神经网络"
    assert raw["_meta"]["卷积神经网络"]["source"] == "manual"


def test_load_missing_file_returns_empty(tmp_path: Path):
    assert gs.load_glossary(str(tmp_path / "nope.json")) == gs.empty_glossary()


def test_save_glossary_creates_parent_dirs(tmp_path: Path):
    path = tmp_path / "a" / "b" / "glossary.json"
    gs.save_glossary(str(path), gs.empty_glossary())
    assert path.is_file()
