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


def test_companion_in_another_directory_protects_raw(tmp_path):
    """RAWs in a subfolder are protected by a JPG sitting elsewhere in the tree."""
    sub = tmp_path / "RAF"
    sub.mkdir()
    raw = _touch(sub / "y.raf")
    jpg = _touch(tmp_path / "y.jpg")  # same stem, different directory
    # The collector hands both to find_orphan_raws (recursive scan of origin).
    assert pruner.find_orphan_raws([raw, jpg]) == []


def test_orphan_in_subfolder_is_found(tmp_path):
    sub = tmp_path / "RAF"
    sub.mkdir()
    orphan = _touch(sub / "lonely.raf")
    paired = _touch(sub / "kept.raf")
    jpg = _touch(tmp_path / "kept.jpg")
    assert pruner.find_orphan_raws([orphan, paired, jpg]) == [orphan]


def test_delete_raw_trashes_by_default(tmp_path, monkeypatch):
    import send2trash
    trashed: list[str] = []
    monkeypatch.setattr(send2trash, "send2trash", trashed.append)
    raw = _touch(tmp_path / "z.raf")
    sidecar = _touch(tmp_path / "z.raf.xmp")
    affected = pruner.delete_raw(raw)
    assert set(affected) == {raw, sidecar}
    assert set(trashed) == {str(raw), str(sidecar)}
    assert raw.exists() and sidecar.exists()  # trash was mocked, nothing removed


def test_delete_raw_hard_removes_file(tmp_path):
    raw = _touch(tmp_path / "z.raf")
    deleted = pruner.delete_raw(raw, hard=True)
    assert deleted == [raw]
    assert not raw.exists()


def test_delete_raw_hard_takes_xmp_sidecar_along(tmp_path):
    raw = _touch(tmp_path / "z.raf")
    sidecar = _touch(tmp_path / "z.raf.xmp")
    deleted = pruner.delete_raw(raw, hard=True)
    assert set(deleted) == {raw, sidecar}
    assert not raw.exists() and not sidecar.exists()
