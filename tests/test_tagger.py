"""Tagger orchestration: out/overwrite/replace/dry-run semantics."""

from __future__ import annotations

from datetime import datetime, timezone

import pytest
from rich.console import Console

from gpsphototag import exif as exif_mod
from gpsphototag.display import StatusDisplay
from gpsphototag.locator import Locator
from gpsphototag.tagger import Tagger, TaggerOptions
from gpsphototag.types import Status, TimedPoint

UTC = timezone.utc


def _make_display(tmp_path):
    return StatusDisplay(console=Console(file=open(tmp_path / "log.txt", "w"), width=120))


def _gpx_at(dt: datetime, lat=10.0, lon=20.0):
    return [TimedPoint(time=dt, lat=lat, lon=lon)]


def test_options_require_destination():
    with pytest.raises(ValueError):
        TaggerOptions()


def test_options_out_and_overwrite_mutually_exclusive(tmp_path):
    with pytest.raises(ValueError):
        TaggerOptions(out_dir=tmp_path / "out", overwrite=True)


def test_tags_photo_in_out_dir(jpeg_factory, tmp_path):
    dt = datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC)
    photo = jpeg_factory("p.jpg", dt)
    locator = Locator(_gpx_at(dt), [], max_time_diff_seconds=60)
    out = tmp_path / "out"
    opts = TaggerOptions(out_dir=out, fallback_tz=UTC)
    tagger = Tagger(locator, opts, _make_display(tmp_path))
    tagger.run([photo])

    written = out / "p.jpg"
    assert written.exists()
    assert exif_mod.has_gps(written)
    # Original was not modified.
    assert not exif_mod.has_gps(photo)


def test_overwrite_in_place(jpeg_factory, tmp_path):
    dt = datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC)
    photo = jpeg_factory("p.jpg", dt)
    locator = Locator(_gpx_at(dt), [], 60)
    tagger = Tagger(locator, TaggerOptions(overwrite=True, fallback_tz=UTC),
                    _make_display(tmp_path))
    tagger.run([photo])
    assert exif_mod.has_gps(photo)


def test_already_tagged_skipped_without_replace(jpeg_factory, tmp_path):
    dt = datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC)
    photo = jpeg_factory("p.jpg", dt)
    exif_mod.write_gps(photo, photo, lat=0.0, lon=0.0)
    locator = Locator(_gpx_at(dt, lat=42.0, lon=43.0), [], 60)
    display = _make_display(tmp_path)
    Tagger(locator, TaggerOptions(overwrite=True, fallback_tz=UTC), display).run([photo])
    assert display.summary.counts.get(Status.ALREADY_TAGGED) == 1


def test_replace_overrides_existing_gps(jpeg_factory, tmp_path):
    import piexif
    dt = datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC)
    photo = jpeg_factory("p.jpg", dt)
    exif_mod.write_gps(photo, photo, lat=0.0, lon=0.0)
    new_lat, new_lon = 48.8566, 2.3522
    locator = Locator(_gpx_at(dt, lat=new_lat, lon=new_lon), [], 60)
    display = _make_display(tmp_path)
    Tagger(locator, TaggerOptions(overwrite=True, replace=True, fallback_tz=UTC),
           display).run([photo])
    assert display.summary.counts.get(Status.REPLACED) == 1

    gps = piexif.load(str(photo))["GPS"]
    # Latitude updated (we don't compare to zero, since original was 0)
    deg, mins, sec = gps[piexif.GPSIFD.GPSLatitude]
    decimal = deg[0] / deg[1] + mins[0] / mins[1] / 60 + sec[0] / sec[1] / 3600
    assert decimal == pytest.approx(new_lat, abs=1e-4)


def test_no_gps_when_locator_returns_none(jpeg_factory, tmp_path):
    dt = datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC)
    photo = jpeg_factory("p.jpg", dt)
    locator = Locator([], [], 60)
    display = _make_display(tmp_path)
    Tagger(locator, TaggerOptions(overwrite=True, fallback_tz=UTC), display).run([photo])
    assert display.summary.counts.get(Status.NO_GPS) == 1
    assert not exif_mod.has_gps(photo)


def test_no_timestamp_when_exif_missing(jpeg_factory, tmp_path):
    photo = jpeg_factory("notime.jpg", None)
    locator = Locator(_gpx_at(datetime(2024, 1, 1, tzinfo=UTC)), [], 60)
    display = _make_display(tmp_path)
    Tagger(locator, TaggerOptions(overwrite=True, fallback_tz=UTC), display).run([photo])
    assert display.summary.counts.get(Status.NO_TIMESTAMP) == 1


def test_dry_run_writes_nothing(jpeg_factory, tmp_path):
    dt = datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC)
    photo = jpeg_factory("p.jpg", dt)
    locator = Locator(_gpx_at(dt), [], 60)
    display = _make_display(tmp_path)
    Tagger(locator, TaggerOptions(dry_run=True, fallback_tz=UTC), display).run([photo])
    assert display.summary.counts.get(Status.DRY_RUN) == 1
    assert not exif_mod.has_gps(photo)


def test_interpolated_status(jpeg_factory, tmp_path):
    dt = datetime(2024, 8, 15, 10, 1, 0, tzinfo=UTC)
    photo = jpeg_factory("p.jpg", dt)
    pts = [
        TimedPoint(time=datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC), lat=0.0, lon=0.0),
        TimedPoint(time=datetime(2024, 8, 15, 10, 2, 0, tzinfo=UTC), lat=2.0, lon=4.0),
    ]
    locator = Locator(pts, [], 300)
    display = _make_display(tmp_path)
    Tagger(locator, TaggerOptions(overwrite=True, fallback_tz=UTC), display).run([photo])
    assert display.summary.counts.get(Status.INTERPOLATED) == 1
