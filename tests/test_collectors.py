"""Tests for path resolution: file, dir-recursive, glob, ext-filter, dedup."""

from __future__ import annotations

from pathlib import Path

from gpsphototag.collectors import GPX_EXTS, PHOTO_EXTS, collect_paths


def _touch(p: Path) -> Path:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(b"")
    return p


def test_collect_single_file(tmp_path):
    f = _touch(tmp_path / "DSC001.jpg")
    out = collect_paths([[str(f)]], PHOTO_EXTS)
    assert out == [f.resolve()]


def test_collect_skips_wrong_extension(tmp_path):
    _touch(tmp_path / "note.txt")
    f = _touch(tmp_path / "DSC001.jpg")
    out = collect_paths([[str(tmp_path / "note.txt"), str(f)]], PHOTO_EXTS)
    assert out == [f.resolve()]


def test_collect_directory_recursive(tmp_path):
    _touch(tmp_path / "a" / "DSC001.jpg")
    _touch(tmp_path / "a" / "b" / "DSC002.JPEG")
    _touch(tmp_path / "a" / "ignore.txt")
    out = collect_paths([[str(tmp_path)]], PHOTO_EXTS)
    assert len(out) == 2
    assert all(p.suffix.lower() in {".jpg", ".jpeg"} for p in out)


def test_collect_glob_pattern(tmp_path, monkeypatch):
    _touch(tmp_path / "DSC001.jpg")
    _touch(tmp_path / "DSC002.jpg")
    _touch(tmp_path / "IMG_001.png")
    monkeypatch.chdir(tmp_path)
    out = collect_paths([["DSC*.jpg"]], PHOTO_EXTS)
    assert {p.name for p in out} == {"DSC001.jpg", "DSC002.jpg"}


def test_collect_dedup_and_sort(tmp_path):
    a = _touch(tmp_path / "b.jpg")
    b = _touch(tmp_path / "a.jpg")
    out = collect_paths([[str(a), str(b)], [str(a)]], PHOTO_EXTS)
    assert out == sorted([a.resolve(), b.resolve()])
    assert len(out) == 2


def test_collect_none_returns_empty():
    assert collect_paths(None, PHOTO_EXTS) == []
    assert collect_paths([], PHOTO_EXTS) == []


def test_collect_gpx_filter(tmp_path):
    _touch(tmp_path / "trip.gpx")
    _touch(tmp_path / "trip.json")
    out = collect_paths([[str(tmp_path)]], GPX_EXTS)
    assert [p.name for p in out] == ["trip.gpx"]


def test_collect_case_insensitive_extension(tmp_path):
    f = _touch(tmp_path / "DSC.JPG")
    out = collect_paths([[str(f)]], PHOTO_EXTS)
    assert out == [f.resolve()]


def test_collect_glob_case_insensitive_lowercase_pattern(tmp_path, monkeypatch):
    _touch(tmp_path / "DSC001.RAF")
    _touch(tmp_path / "DSC002.raf")
    _touch(tmp_path / "IMG.JPG")
    monkeypatch.chdir(tmp_path)
    out = collect_paths([["*.raf"]], PHOTO_EXTS)
    assert {p.name for p in out} == {"DSC001.RAF", "DSC002.raf"}


def test_collect_glob_case_insensitive_uppercase_pattern(tmp_path, monkeypatch):
    _touch(tmp_path / "a.jpg")
    _touch(tmp_path / "b.JPG")
    _touch(tmp_path / "c.raf")
    monkeypatch.chdir(tmp_path)
    out = collect_paths([["*.JPG"]], PHOTO_EXTS)
    assert {p.name for p in out} == {"a.jpg", "b.JPG"}


def test_collect_glob_preserves_character_classes(tmp_path, monkeypatch):
    _touch(tmp_path / "IMG_1.RAF")
    _touch(tmp_path / "IMG_2.raf")
    _touch(tmp_path / "IMG_x.raf")
    monkeypatch.chdir(tmp_path)
    out = collect_paths([["IMG_[0-9].raf"]], PHOTO_EXTS)
    assert {p.name for p in out} == {"IMG_1.RAF", "IMG_2.raf"}


def test_collect_glob_no_match_warns(tmp_path, monkeypatch, caplog):
    monkeypatch.chdir(tmp_path)
    with caplog.at_level("WARNING"):
        out = collect_paths([["nothing-*.jpg"]], PHOTO_EXTS)
    assert out == []
    assert any("No matches" in r.message for r in caplog.records)
