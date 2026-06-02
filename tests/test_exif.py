"""EXIF read/write: timestamp parsing + GPS round-trip on real images."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import piexif
import pytest

from gpsphototag import exif as exif_mod

UTC = timezone.utc
TZ_PARIS = timezone(timedelta(hours=2))


def test_read_timestamp_with_offset(jpeg_factory):
    dt = datetime(2024, 8, 15, 12, 0, 0, tzinfo=TZ_PARIS)
    path = jpeg_factory("with_offset.jpg", dt, with_offset=True)
    got = exif_mod.read_timestamp(path, fallback_tz=UTC)
    assert got is not None
    assert got.utcoffset() == timedelta(hours=2)
    assert got.astimezone(UTC) == datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC)


def test_read_timestamp_without_offset_uses_fallback(jpeg_factory):
    dt = datetime(2024, 8, 15, 10, 0, 0)
    path = jpeg_factory("naive.jpg", dt, with_offset=False)
    got = exif_mod.read_timestamp(path, fallback_tz=UTC)
    assert got is not None
    assert got.tzinfo == UTC


def test_read_timestamp_returns_none_when_missing(jpeg_factory):
    path = jpeg_factory("no_exif.jpg", None)
    got = exif_mod.read_timestamp(path, fallback_tz=UTC)
    assert got is None


def test_has_gps_false_then_true(jpeg_factory):
    path = jpeg_factory("no_gps.jpg", datetime(2024, 8, 15, tzinfo=UTC))
    assert exif_mod.has_gps(path) is False
    exif_mod.write_gps(path, path, lat=48.8566, lon=2.3522)
    assert exif_mod.has_gps(path) is True


def test_write_gps_jpeg_round_trip(jpeg_factory, tmp_path):
    src = jpeg_factory("photo.jpg", datetime(2024, 8, 15, tzinfo=UTC))
    dst = tmp_path / "out.jpg"
    exif_mod.write_gps(src, dst, lat=48.8566, lon=2.3522)

    exif_dict = piexif.load(str(dst))
    gps = exif_dict["GPS"]
    assert gps[piexif.GPSIFD.GPSLatitudeRef] == b"N"
    assert gps[piexif.GPSIFD.GPSLongitudeRef] == b"E"

    # Reconstruct decimal degrees from DMS rationals and check accuracy.
    def to_deg(triple):
        d = triple[0][0] / triple[0][1]
        m = triple[1][0] / triple[1][1]
        s = triple[2][0] / triple[2][1]
        return d + m / 60 + s / 3600

    assert to_deg(gps[piexif.GPSIFD.GPSLatitude]) == pytest.approx(48.8566, abs=1e-5)
    assert to_deg(gps[piexif.GPSIFD.GPSLongitude]) == pytest.approx(2.3522, abs=1e-5)


def test_write_gps_negative_coords_sets_refs(jpeg_factory, tmp_path):
    src = jpeg_factory("sw.jpg", datetime(2024, 8, 15, tzinfo=UTC))
    dst = tmp_path / "sw_out.jpg"
    exif_mod.write_gps(src, dst, lat=-33.86, lon=-151.21)
    exif_dict = piexif.load(str(dst))
    gps = exif_dict["GPS"]
    assert gps[piexif.GPSIFD.GPSLatitudeRef] == b"S"
    assert gps[piexif.GPSIFD.GPSLongitudeRef] == b"W"


def test_write_gps_png_round_trip(png_factory, tmp_path):
    src = png_factory("photo.png", datetime(2024, 8, 15, tzinfo=UTC))
    dst = tmp_path / "out.png"
    exif_mod.write_gps(src, dst, lat=10.0, lon=20.0)
    assert exif_mod.has_gps(dst)


def test_write_gps_in_place(jpeg_factory):
    p = jpeg_factory("inplace.jpg", datetime(2024, 8, 15, tzinfo=UTC))
    exif_mod.write_gps(p, p, lat=1.0, lon=2.0)
    assert exif_mod.has_gps(p)


def test_write_gps_unsupported_extension(tmp_path):
    f = tmp_path / "x.txt"
    f.write_text("hello")
    with pytest.raises(ValueError):
        exif_mod.write_gps(f, f, lat=0.0, lon=0.0)
