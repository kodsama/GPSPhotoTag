"""Pruner: orphan-RAW detection and deletion (with XMP sidecar)."""

from __future__ import annotations

from gpsphototag import pruner


def _touch(path):
    path.write_bytes(b"x")
    return path


def test_raw_without_companion_is_orphan(tmp_path):
    raw = _touch(tmp_path / "DSCF0001.RAF")
    assert pruner.find_orphan_raws([raw]) == [raw]


def test_raw_with_same_name_jpg_is_kept(tmp_path):
    raw = _touch(tmp_path / "DSCF0001.RAF")
    _touch(tmp_path / "DSCF0001.JPG")
    assert pruner.find_orphan_raws([raw]) == []


def test_companion_match_is_case_insensitive(tmp_path):
    raw = _touch(tmp_path / "dscf0001.raf")
    _touch(tmp_path / "DSCF0001.JPG")
    assert pruner.find_orphan_raws([raw]) == []


def test_jpeg_and_heic_count_as_companions(tmp_path):
    a = _touch(tmp_path / "a.RAF")
    _touch(tmp_path / "a.jpeg")
    b = _touch(tmp_path / "b.RAF")
    _touch(tmp_path / "b.heic")
    assert pruner.find_orphan_raws([a, b]) == []


def test_companion_found_on_disk_even_if_not_in_photo_list(tmp_path):
    """User passed only *.raf — the JPG next to it still protects the RAW."""
    raw = _touch(tmp_path / "x.raf")
    _touch(tmp_path / "x.jpg")  # on disk but not in the list
    assert pruner.find_orphan_raws([raw]) == []


def test_another_raw_is_not_a_companion(tmp_path):
    raf = _touch(tmp_path / "x.raf")
    _touch(tmp_path / "x.dng")  # RAW, not a native companion
    assert pruner.find_orphan_raws([raf]) == [raf]


def test_non_raw_photos_are_ignored(tmp_path):
    jpg = _touch(tmp_path / "solo.jpg")
    assert pruner.find_orphan_raws([jpg]) == []


def test_companions_only_match_within_same_directory(tmp_path):
    sub = tmp_path / "sub"
    sub.mkdir()
    raw = _touch(sub / "y.raf")
    _touch(tmp_path / "y.jpg")  # same stem, different directory
    assert pruner.find_orphan_raws([raw]) == [raw]


def test_delete_raw_removes_file(tmp_path):
    raw = _touch(tmp_path / "z.raf")
    deleted = pruner.delete_raw(raw)
    assert deleted == [raw]
    assert not raw.exists()


def test_delete_raw_takes_xmp_sidecar_along(tmp_path):
    raw = _touch(tmp_path / "z.raf")
    sidecar = _touch(tmp_path / "z.raf.xmp")
    deleted = pruner.delete_raw(raw)
    assert set(deleted) == {raw, sidecar}
    assert not raw.exists() and not sidecar.exists()
