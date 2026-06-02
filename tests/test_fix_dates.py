"""--fix-dates: EXIF datetime writes + tagger date-fixing flow."""

from __future__ import annotations

import os
from datetime import datetime, timezone

import pytest
from rich.console import Console

from gpsphototag import dates
from gpsphototag import exif as exif_mod
from gpsphototag.display import StatusDisplay
from gpsphototag.locator import Locator
from gpsphototag.tagger import Tagger, TaggerOptions
from gpsphototag.types import Status, TimedPoint

UTC = timezone.utc


def _display(tmp_path):
    return StatusDisplay(console=Console(file=open(tmp_path / "out.txt", "w"), width=140))


def _read_exif_dt(path):
    ts = exif_mod.read_timestamp(path, fallback_tz=UTC)
    return ts


# ---------------------------------------------------------------------------
# exif.apply_exif datetime
# ---------------------------------------------------------------------------
def test_apply_exif_writes_datetime_jpeg(jpeg_factory, tmp_path):
    src = jpeg_factory("p.jpg", datetime(2020, 1, 1, tzinfo=UTC))
    dst = tmp_path / "out.jpg"
    new_dt = datetime(2024, 8, 15, 10, 30, 0, tzinfo=UTC)
    exif_mod.apply_exif(src, dst, dt=new_dt)
    got = _read_exif_dt(dst)
    assert got.replace(tzinfo=None) == new_dt.replace(tzinfo=None)


def test_apply_exif_writes_gps_and_datetime_together(jpeg_factory, tmp_path):
    """Both written in one pass — GPS is not clobbered by the datetime write."""
    src = jpeg_factory("p.jpg", datetime(2020, 1, 1, tzinfo=UTC))
    dst = tmp_path / "out.jpg"
    new_dt = datetime(2024, 8, 15, 10, 30, 0, tzinfo=UTC)
    exif_mod.apply_exif(src, dst, gps=(48.8566, 2.3522), dt=new_dt)
    assert exif_mod.has_gps(dst)
    assert _read_exif_dt(dst).replace(tzinfo=None) == new_dt.replace(tzinfo=None)


def test_apply_exif_writes_datetime_png(png_factory, tmp_path):
    src = png_factory("p.png", datetime(2020, 1, 1, tzinfo=UTC))
    dst = tmp_path / "out.png"
    new_dt = datetime(2024, 8, 15, 9, 0, 0, tzinfo=UTC)
    exif_mod.apply_exif(src, dst, dt=new_dt)
    assert _read_exif_dt(dst).replace(tzinfo=None) == new_dt.replace(tzinfo=None)


def test_apply_exif_raw_datetime_sidecar_rejected(dng_factory, tmp_path):
    """A datetime write into a RAW file in sidecar mode is rejected."""
    raw = dng_factory("p.dng", datetime(2020, 1, 1, tzinfo=UTC))
    with pytest.raises(ValueError, match="require --raw-mode embed"):
        exif_mod.apply_exif(raw, raw, dt=datetime(2024, 8, 15, tzinfo=UTC), raw_mode="sidecar")


# ---------------------------------------------------------------------------
# --fix-dates exif : file date <- EXIF timestamp
# ---------------------------------------------------------------------------
def test_fix_dates_exif_sets_file_mtime_from_exif(jpeg_factory, tmp_path):
    exif_dt = datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC)
    photo = jpeg_factory("p.jpg", exif_dt)
    # Make current mtime clearly different.
    os.utime(photo, (0, 0))
    display = _display(tmp_path)
    Tagger(Locator([], [], 60),
           TaggerOptions(overwrite=True, fallback_tz=UTC, fix_dates="exif"),
           display).run([photo])
    assert display.summary.counts.get(Status.DATES_FIXED) == 1
    assert abs(photo.stat().st_mtime - exif_dt.timestamp()) < 2


def test_fix_dates_exif_no_timestamp_reports_no_timestamp(jpeg_factory, tmp_path):
    photo = jpeg_factory("notime.jpg", None)
    display = _display(tmp_path)
    Tagger(Locator([], [], 60),
           TaggerOptions(overwrite=True, fallback_tz=UTC, fix_dates="exif"),
           display).run([photo])
    # No EXIF ts and no GPS source → NO_TIMESTAMP.
    assert display.summary.counts.get(Status.NO_TIMESTAMP) == 1


# ---------------------------------------------------------------------------
# --fix-dates file : EXIF DateTimeOriginal <- file created date
# ---------------------------------------------------------------------------
def test_fix_dates_file_writes_exif_from_file_date(jpeg_factory, tmp_path, monkeypatch):
    photo = jpeg_factory("nodt.jpg", None)  # no EXIF datetime
    file_created = datetime(2024, 8, 15, 14, 25, 0, tzinfo=UTC)
    monkeypatch.setattr(dates, "read_file_created", lambda p: file_created)

    display = _display(tmp_path)
    Tagger(Locator([], [], 60),
           TaggerOptions(overwrite=True, fallback_tz=UTC, fix_dates="file"),
           display).run([photo])
    assert display.summary.counts.get(Status.DATES_FIXED) == 1
    got = _read_exif_dt(photo)
    assert got is not None
    assert got.replace(tzinfo=None) == file_created.replace(tzinfo=None)


# ---------------------------------------------------------------------------
# Combined with GPS
# ---------------------------------------------------------------------------
def test_fix_dates_combined_with_gps_tagging(jpeg_factory, tmp_path):
    exif_dt = datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC)
    photo = jpeg_factory("p.jpg", exif_dt)
    os.utime(photo, (0, 0))
    locator = Locator([TimedPoint(time=exif_dt, lat=48.8566, lon=2.3522)], [], 60)
    display = _display(tmp_path)
    Tagger(locator, TaggerOptions(overwrite=True, fallback_tz=UTC, fix_dates="exif"),
           display).run([photo])
    # GPS status wins; dates still applied.
    assert display.summary.counts.get(Status.TAGGED) == 1
    assert exif_mod.has_gps(photo)
    assert abs(photo.stat().st_mtime - exif_dt.timestamp()) < 2


# ---------------------------------------------------------------------------
# --out behavior: file fixed in the copy, original untouched
# ---------------------------------------------------------------------------
def test_fix_dates_exif_into_out_dir(jpeg_factory, tmp_path):
    exif_dt = datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC)
    photo = jpeg_factory("p.jpg", exif_dt)
    os.utime(photo, (0, 0))
    out = tmp_path / "out"
    display = _display(tmp_path)
    Tagger(Locator([], [], 60),
           TaggerOptions(out_dir=out, fallback_tz=UTC, fix_dates="exif"),
           display).run([photo])
    copied = out / "p.jpg"
    assert copied.exists()
    assert abs(copied.stat().st_mtime - exif_dt.timestamp()) < 2


# ---------------------------------------------------------------------------
# RAW + file mode in sidecar mode is skipped with a clear note
# ---------------------------------------------------------------------------
def test_fix_dates_file_raw_sidecar_skipped(dng_factory, tmp_path):
    photo = dng_factory("p.dng", datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC))
    display = _display(tmp_path)
    Tagger(Locator([], [], 60),
           TaggerOptions(overwrite=True, fallback_tz=UTC, fix_dates="file",
                         raw_mode="sidecar"),
           display).run([photo])
    text = (tmp_path / "out.txt").read_text()
    assert "--raw-mode embed" in text


def test_fix_dates_exif_works_for_raw(dng_factory, tmp_path):
    """exif-mode date fixing works for RAW (reads via exifread, sets fs dates)."""
    exif_dt = datetime(2024, 8, 15, 10, 0, 0)
    photo = dng_factory("p.dng", exif_dt)
    os.utime(photo, (0, 0))
    display = _display(tmp_path)
    Tagger(Locator([], [], 60),
           TaggerOptions(overwrite=True, fallback_tz=UTC, fix_dates="exif"),
           display).run([photo])
    assert display.summary.counts.get(Status.DATES_FIXED) == 1
    assert abs(photo.stat().st_mtime - exif_dt.replace(tzinfo=UTC).timestamp()) < 3700


# ---------------------------------------------------------------------------
# dry-run reports intent, writes nothing
# ---------------------------------------------------------------------------
def test_fix_dates_dry_run_writes_nothing(jpeg_factory, tmp_path):
    exif_dt = datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC)
    photo = jpeg_factory("p.jpg", exif_dt)
    os.utime(photo, (0, 0))
    display = _display(tmp_path)
    Tagger(Locator([], [], 60),
           TaggerOptions(dry_run=True, fallback_tz=UTC, fix_dates="exif"),
           display).run([photo])
    assert display.summary.counts.get(Status.DRY_RUN) == 1
    assert photo.stat().st_mtime == 0  # untouched
    assert "file date ← EXIF" in (tmp_path / "out.txt").read_text()


def test_tagger_options_invalid_fix_dates():
    with pytest.raises(ValueError, match="fix_dates"):
        TaggerOptions(overwrite=True, fix_dates="bogus")
