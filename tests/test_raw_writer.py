"""RAW support: read via exifread, write via sidecar / exiftool subprocess."""

from __future__ import annotations

import subprocess
from datetime import datetime, timezone
from pathlib import Path

import pytest

from gpsphototag import exif as exif_mod
from gpsphototag import raw_writer
from gpsphototag.collectors import PHOTO_EXTS, RAW_EXTS

UTC = timezone.utc


# ---------------------------------------------------------------------------
# Collectors recognize RAW extensions
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("ext", [".raf", ".nef", ".cr2", ".cr3", ".arw", ".dng",
                                  ".rw2", ".orf", ".pef", ".srw", ".x3f"])
def test_raw_extensions_are_recognized_as_photos(ext):
    """Every RAW extension we claim to support is in PHOTO_EXTS."""
    assert ext in PHOTO_EXTS
    assert ext in RAW_EXTS


# ---------------------------------------------------------------------------
# XMP formatting
# ---------------------------------------------------------------------------
def test_to_xmp_coord_north_east():
    assert raw_writer._to_xmp_coord(48.8566, is_latitude=True) == "48,51.39600N"
    assert raw_writer._to_xmp_coord(2.3522, is_latitude=False) == "2,21.13200E"


def test_to_xmp_coord_south_west():
    assert raw_writer._to_xmp_coord(-33.86, is_latitude=True).endswith("S")
    assert raw_writer._to_xmp_coord(-151.21, is_latitude=False).endswith("W")


def test_build_xmp_contains_required_tags():
    xmp = raw_writer.build_xmp(lat=48.8566, lon=2.3522)
    assert "<exif:GPSLatitude>" in xmp
    assert "<exif:GPSLongitude>" in xmp
    assert "WGS-84" in xmp
    assert xmp.startswith("<?xml")


# ---------------------------------------------------------------------------
# Sidecar writes
# ---------------------------------------------------------------------------
def test_sidecar_path_for_appends_xmp():
    assert raw_writer.sidecar_path_for(Path("a.raf")) == Path("a.raf.xmp")
    assert raw_writer.sidecar_path_for(Path("/x/b.NEF")) == Path("/x/b.NEF.xmp")


def test_write_sidecar_in_place(dng_factory):
    raw = dng_factory("p.dng", datetime(2024, 8, 15, tzinfo=UTC))
    side = raw_writer.write_sidecar(raw, raw, lat=48.8566, lon=2.3522)
    assert side == raw_writer.sidecar_path_for(raw)
    assert side.exists()
    content = side.read_text(encoding="utf-8")
    assert "<exif:GPSLatitude>48,51.39600N</exif:GPSLatitude>" in content


def test_write_sidecar_to_out_dir_copies_raw(dng_factory, tmp_path):
    raw = dng_factory("p.dng", datetime(2024, 8, 15, tzinfo=UTC))
    out = tmp_path / "out"
    dst = out / "p.dng"
    side = raw_writer.write_sidecar(raw, dst, lat=1.0, lon=2.0)
    assert dst.exists() and side.exists()
    assert side.parent == out


# ---------------------------------------------------------------------------
# Read via exifread
# ---------------------------------------------------------------------------
def test_read_raw_metadata_timestamp(dng_factory):
    raw = dng_factory("p.dng", datetime(2024, 8, 15, 10, 0, 0))
    ts, gps = raw_writer.read_raw_metadata(raw, fallback_tz=UTC)
    assert ts is not None
    assert ts.year == 2024 and ts.month == 8 and ts.day == 15
    assert ts.tzinfo == UTC
    assert gps is False


def test_read_raw_metadata_has_gps_in_raw(dng_factory):
    raw = dng_factory("p.dng", datetime(2024, 8, 15), with_gps=True)
    _, gps = raw_writer.read_raw_metadata(raw, fallback_tz=UTC)
    assert gps is True


def test_read_raw_metadata_missing(tmp_path):
    bad = tmp_path / "broken.raf"
    bad.write_bytes(b"not a real raw file")
    ts, gps = raw_writer.read_raw_metadata(bad, fallback_tz=UTC)
    assert ts is None and gps is False


# ---------------------------------------------------------------------------
# exif.write_gps dispatches RAW
# ---------------------------------------------------------------------------
def test_exif_write_gps_dispatches_raw_to_sidecar(dng_factory):
    raw = dng_factory("dispatch.dng", datetime(2024, 8, 15, tzinfo=UTC))
    exif_mod.write_gps(raw, raw, lat=10.0, lon=20.0, raw_mode="sidecar")
    assert raw_writer.sidecar_path_for(raw).exists()


def test_exif_read_timestamp_routes_raw_through_exifread(dng_factory):
    raw = dng_factory("ts.dng", datetime(2024, 8, 15, 9, 30, 0))
    ts = exif_mod.read_timestamp(raw, fallback_tz=UTC)
    assert ts is not None and ts.hour == 9 and ts.minute == 30


def test_exif_has_gps_true_when_sidecar_present(dng_factory):
    raw = dng_factory("h.dng", datetime(2024, 8, 15, tzinfo=UTC))
    assert exif_mod.has_gps(raw) is False
    raw_writer.write_sidecar(raw, raw, lat=1.0, lon=2.0)
    assert exif_mod.has_gps(raw) is True


# ---------------------------------------------------------------------------
# exiftool subprocess (mocked)
# ---------------------------------------------------------------------------
def test_write_embedded_invokes_exiftool(monkeypatch, dng_factory):
    raw = dng_factory("e.dng", datetime(2024, 8, 15, tzinfo=UTC))
    calls: list[list[str]] = []

    def fake_run(cmd, capture_output, text, check):
        calls.append(cmd)
        return subprocess.CompletedProcess(cmd, returncode=0, stdout="", stderr="")

    monkeypatch.setattr(raw_writer, "exiftool_available", lambda: True)
    monkeypatch.setattr(subprocess, "run", fake_run)
    raw_writer.write_embedded(raw, raw, gps=(48.8566, 2.3522))
    assert calls and calls[0][0] == "exiftool"
    assert any("GPSLatitude=48.8566" in c for c in calls[0])
    assert "-GPSLatitudeRef=N" in calls[0]


def test_write_embedded_writes_datetime(monkeypatch, dng_factory):
    """gps=None, dt set → exiftool gets DateTimeOriginal, no GPS args."""
    raw = dng_factory("e.dng", datetime(2024, 8, 15, tzinfo=UTC))
    calls: list[list[str]] = []
    monkeypatch.setattr(raw_writer, "exiftool_available", lambda: True)
    monkeypatch.setattr(subprocess, "run",
                        lambda cmd, **k: calls.append(cmd) or subprocess.CompletedProcess(cmd, 0, "", ""))
    raw_writer.write_embedded(raw, raw, dt=datetime(2024, 8, 15, 10, 30, 0, tzinfo=UTC))
    assert any("DateTimeOriginal=2024:08:15 10:30:00" in c for c in calls[0])
    assert not any("GPSLatitude" in c for c in calls[0])


def test_write_embedded_requires_a_field(dng_factory):
    raw = dng_factory("e.dng", datetime(2024, 8, 15, tzinfo=UTC))
    with pytest.raises(ValueError, match="requires gps and/or dt"):
        raw_writer.write_embedded(raw, raw)


def test_write_embedded_failure_raises(monkeypatch, dng_factory):
    raw = dng_factory("e.dng", datetime(2024, 8, 15, tzinfo=UTC))
    monkeypatch.setattr(raw_writer, "exiftool_available", lambda: True)

    def fake_run(cmd, capture_output, text, check):
        return subprocess.CompletedProcess(cmd, returncode=1, stdout="", stderr="boom")

    monkeypatch.setattr(subprocess, "run", fake_run)
    with pytest.raises(RuntimeError, match="exiftool failed"):
        raw_writer.write_embedded(raw, raw, gps=(0.0, 0.0))


def test_write_embedded_requires_exiftool(monkeypatch, dng_factory):
    raw = dng_factory("e.dng", datetime(2024, 8, 15, tzinfo=UTC))
    monkeypatch.setattr(raw_writer, "exiftool_available", lambda: False)
    with pytest.raises(RuntimeError, match="exiftool not found"):
        raw_writer.write_embedded(raw, raw, gps=(0.0, 0.0))


def test_write_embedded_copies_to_dst_when_different(monkeypatch, dng_factory, tmp_path):
    raw = dng_factory("e.dng", datetime(2024, 8, 15, tzinfo=UTC))
    dst = tmp_path / "out" / "e.dng"
    monkeypatch.setattr(raw_writer, "exiftool_available", lambda: True)
    monkeypatch.setattr(
        subprocess, "run",
        lambda *a, **k: subprocess.CompletedProcess([], 0, "", ""),
    )
    raw_writer.write_embedded(raw, dst, gps=(0.0, 0.0))
    assert dst.exists()


def test_exiftool_available_returns_bool():
    """The probe never raises; it's a yes/no check."""
    assert isinstance(raw_writer.exiftool_available(), bool)


def test_resolve_raw_mode_auto_prefers_embed_when_exiftool_present(monkeypatch):
    monkeypatch.setattr(raw_writer, "exiftool_available", lambda: True)
    assert raw_writer.resolve_raw_mode("auto") == "embed"


def test_resolve_raw_mode_auto_falls_back_to_sidecar(monkeypatch):
    monkeypatch.setattr(raw_writer, "exiftool_available", lambda: False)
    assert raw_writer.resolve_raw_mode("auto") == "sidecar"


def test_resolve_raw_mode_explicit_passthrough():
    assert raw_writer.resolve_raw_mode("sidecar") == "sidecar"
    assert raw_writer.resolve_raw_mode("embed") == "embed"


def test_apply_exif_auto_embeds_when_exiftool_available(monkeypatch, dng_factory):
    """exif.apply_exif RAW + auto → embed when exiftool is available."""
    raw = dng_factory("a.dng", datetime(2024, 8, 15, tzinfo=UTC))
    calls: list = []
    monkeypatch.setattr(raw_writer, "exiftool_available", lambda: True)
    monkeypatch.setattr(raw_writer, "write_embedded",
                        lambda src, dst, *, gps=None, dt=None: calls.append(gps))
    exif_mod.apply_exif(raw, raw, gps=(1.0, 2.0), raw_mode="auto")
    assert calls == [(1.0, 2.0)]


def test_apply_exif_auto_sidecar_when_no_exiftool(monkeypatch, dng_factory):
    """exif.apply_exif RAW + auto → sidecar when exiftool is absent."""
    raw = dng_factory("a.dng", datetime(2024, 8, 15, tzinfo=UTC))
    monkeypatch.setattr(raw_writer, "exiftool_available", lambda: False)
    exif_mod.apply_exif(raw, raw, gps=(1.0, 2.0), raw_mode="auto")
    assert raw_writer.sidecar_path_for(raw).exists()


def test_parse_offset_in_raw_writer():
    assert raw_writer._parse_offset("Z") is timezone.utc
    assert raw_writer._parse_offset("+02:00").utcoffset(None).total_seconds() == 2 * 3600
    assert raw_writer._parse_offset("garbage") is None


def test_read_raw_metadata_unparseable_datetime_returns_none(monkeypatch, dng_factory):
    """A non-conforming DateTime string yields None for ts, preserves has_gps."""
    raw = dng_factory("p.dng", datetime(2024, 8, 15, tzinfo=UTC), with_gps=True)

    class FakeTag:
        def __str__(self):
            return "not a real date"

    def fake_process_file(fh, **kwargs):
        return {"EXIF DateTimeOriginal": FakeTag(), "GPS GPSLatitude": object()}

    monkeypatch.setattr(raw_writer.exifread, "process_file", fake_process_file)
    monkeypatch.setattr(raw_writer, "exiftool_available", lambda: False)  # isolate exifread path
    ts, gps = raw_writer.read_raw_metadata(raw, fallback_tz=UTC)
    assert ts is None
    assert gps is True


def test_read_raw_metadata_exifread_exception(monkeypatch, dng_factory):
    raw = dng_factory("p.dng", datetime(2024, 8, 15, tzinfo=UTC))

    def boom(*a, **kw):
        raise RuntimeError("exifread blew up")

    monkeypatch.setattr(raw_writer.exifread, "process_file", boom)
    monkeypatch.setattr(raw_writer, "exiftool_available", lambda: False)  # isolate exifread path
    ts, gps = raw_writer.read_raw_metadata(raw, fallback_tz=UTC)
    assert ts is None and gps is False


def test_read_raw_metadata_with_offset_tag(monkeypatch, dng_factory):
    """RAW EXIF with OffsetTimeOriginal applies the offset rather than fallback."""
    raw = dng_factory("p.dng", datetime(2024, 8, 15, tzinfo=UTC))

    class T:
        def __init__(self, s):
            self._s = s
        def __str__(self):
            return self._s

    monkeypatch.setattr(raw_writer.exifread, "process_file", lambda *a, **k: {
        "EXIF DateTimeOriginal": T("2024:08:15 10:00:00"),
        "EXIF OffsetTimeOriginal": T("+02:00"),
    })
    ts, _ = raw_writer.read_raw_metadata(raw, fallback_tz=UTC)
    from datetime import timedelta
    assert ts.utcoffset() == timedelta(hours=2)


def test_exif_write_gps_raw_embed_calls_raw_writer(monkeypatch, dng_factory):
    """write_gps with raw_mode='embed' routes to raw_writer.write_embedded."""
    raw = dng_factory("e.dng", datetime(2024, 8, 15, tzinfo=UTC))
    called: list = []

    def fake_embed(src, dst, *, gps=None, dt=None):
        called.append((src, dst, gps, dt))

    monkeypatch.setattr(raw_writer, "write_embedded", fake_embed)
    exif_mod.write_gps(raw, raw, lat=1.0, lon=2.0, raw_mode="embed")
    assert called and called[0][2] == (1.0, 2.0)


def test_tagger_options_invalid_raw_mode():
    from gpsphototag.tagger import TaggerOptions
    with pytest.raises(ValueError, match="raw_mode"):
        TaggerOptions(overwrite=True, raw_mode="bogus")


# ---------------------------------------------------------------------------
# exiftool read fallback (Fujifilm .RAF, Canon .CR3 — formats exifread can't
# parse). Regression for "File format not recognized." → no_timestamp.
# ---------------------------------------------------------------------------
def _exiftool_json(**fields):
    import json
    return json.dumps([{"SourceFile": "x", **fields}])


def test_raf_falls_back_to_exiftool_for_timestamp(monkeypatch, tmp_path):
    """exifread can't read RAF → exiftool fallback supplies the timestamp."""
    raf = tmp_path / "DSCF0481.RAF"
    raf.write_bytes(b"FUJIFILMCCD-RAW 0201" + b"\x00" * 256)

    monkeypatch.setattr(raw_writer.exifread, "process_file", lambda *a, **k: {})  # unrecognized
    monkeypatch.setattr(raw_writer, "exiftool_available", lambda: True)
    monkeypatch.setattr(raw_writer.subprocess, "run", lambda *a, **k:
                        subprocess.CompletedProcess([], 0,
                                                    _exiftool_json(DateTimeOriginal="2024:08:15 10:30:00"), ""))
    ts, gps = raw_writer.read_raw_metadata(raf, fallback_tz=UTC)
    assert ts is not None
    assert (ts.year, ts.month, ts.day, ts.hour, ts.minute) == (2024, 8, 15, 10, 30)
    assert gps is False


def test_raf_exiftool_detects_existing_gps(monkeypatch, tmp_path):
    raf = tmp_path / "x.RAF"
    raf.write_bytes(b"FUJIFILMCCD-RAW " + b"\x00" * 64)
    monkeypatch.setattr(raw_writer.exifread, "process_file", lambda *a, **k: {})
    monkeypatch.setattr(raw_writer, "exiftool_available", lambda: True)
    monkeypatch.setattr(raw_writer.subprocess, "run", lambda *a, **k:
                        subprocess.CompletedProcess([], 0,
                                                    _exiftool_json(GPSLatitude="48 deg N"), ""))
    ts, gps = raw_writer.read_raw_metadata(raf, fallback_tz=UTC)
    assert ts is None and gps is True


def test_raf_without_exiftool_warns(monkeypatch, tmp_path, caplog):
    raf = tmp_path / "x.RAF"
    raf.write_bytes(b"FUJIFILMCCD-RAW " + b"\x00" * 64)
    monkeypatch.setattr(raw_writer.exifread, "process_file", lambda *a, **k: {})
    monkeypatch.setattr(raw_writer, "exiftool_available", lambda: False)
    with caplog.at_level("WARNING"):
        ts, gps = raw_writer.read_raw_metadata(raf, fallback_tz=UTC)
    assert ts is None and gps is False
    assert any("exiftool" in r.message for r in caplog.records)


def test_read_with_exiftool_applies_offset(monkeypatch, tmp_path):
    raf = tmp_path / "x.RAF"
    raf.write_bytes(b"FUJIFILMCCD-RAW ")
    monkeypatch.setattr(raw_writer, "exiftool_available", lambda: True)
    monkeypatch.setattr(raw_writer.subprocess, "run", lambda *a, **k:
                        subprocess.CompletedProcess([], 0,
                                                    _exiftool_json(DateTimeOriginal="2024:08:15 10:00:00",
                                                                   OffsetTimeOriginal="+02:00"), ""))
    from datetime import timedelta
    ts, _ = raw_writer._read_with_exiftool(raf, fallback_tz=UTC)
    assert ts.utcoffset() == timedelta(hours=2)


def test_read_with_exiftool_unavailable_returns_none(monkeypatch, tmp_path):
    monkeypatch.setattr(raw_writer, "exiftool_available", lambda: False)
    ts, gps = raw_writer._read_with_exiftool(tmp_path / "x.RAF", fallback_tz=UTC)
    assert ts is None and gps is False


def test_read_with_exiftool_handles_bad_output(monkeypatch, tmp_path):
    monkeypatch.setattr(raw_writer, "exiftool_available", lambda: True)
    monkeypatch.setattr(raw_writer.subprocess, "run", lambda *a, **k:
                        subprocess.CompletedProcess([], 1, "", "error"))
    assert raw_writer._read_with_exiftool(tmp_path / "x.RAF", fallback_tz=UTC) == (None, False)

    monkeypatch.setattr(raw_writer.subprocess, "run", lambda *a, **k:
                        subprocess.CompletedProcess([], 0, "not json", ""))
    assert raw_writer._read_with_exiftool(tmp_path / "x.RAF", fallback_tz=UTC) == (None, False)


@pytest.mark.skipif(not raw_writer.exiftool_available(), reason="exiftool not installed")
def test_read_with_exiftool_real_roundtrip(dng_factory):
    """Real exiftool subprocess reads DateTimeOriginal from a generated file."""
    raw = dng_factory("real.dng", datetime(2024, 8, 15, 9, 30, 0))
    ts, _ = raw_writer._read_with_exiftool(raw, fallback_tz=UTC)
    assert ts is not None
    assert (ts.hour, ts.minute) == (9, 30)
