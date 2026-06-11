"""Shared pytest fixtures.

Fixtures generate real on-disk artifacts (tiny JPEG/PNG/HEIC, GPX, Google
JSON/KML). Generating beats committing binary fixtures: deterministic, easy
to inspect, no LFS.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

import piexif
import pytest
from PIL import Image

try:
    import pillow_heif  # type: ignore
    pillow_heif.register_heif_opener()
    _HEIF_AVAILABLE = True
except Exception:  # pragma: no cover
    _HEIF_AVAILABLE = False


def _exif_with_datetime(dt: datetime, *, with_offset: bool = True) -> bytes:
    """Build EXIF bytes containing DateTimeOriginal (+ OffsetTimeOriginal)."""
    s = dt.strftime("%Y:%m:%d %H:%M:%S")
    exif_dict: dict = {"0th": {}, "Exif": {}, "GPS": {}, "1st": {}, "thumbnail": None}
    exif_dict["Exif"][piexif.ExifIFD.DateTimeOriginal] = s.encode("ascii")
    exif_dict["Exif"][piexif.ExifIFD.DateTimeDigitized] = s.encode("ascii")
    exif_dict["0th"][piexif.ImageIFD.DateTime] = s.encode("ascii")
    if with_offset and dt.utcoffset() is not None:
        offset = dt.utcoffset()
        total_min = int(offset.total_seconds() // 60)
        sign = "+" if total_min >= 0 else "-"
        total_min = abs(total_min)
        offset_str = f"{sign}{total_min // 60:02d}:{total_min % 60:02d}"
        exif_dict["Exif"][piexif.ExifIFD.OffsetTimeOriginal] = offset_str.encode("ascii")
    return piexif.dump(exif_dict)


def _make_jpeg(path: Path, dt: datetime | None, *, with_offset: bool = True, color=(200, 50, 50)) -> Path:
    img = Image.new("RGB", (8, 8), color)
    if dt is not None:
        img.save(path, format="JPEG", exif=_exif_with_datetime(dt, with_offset=with_offset))
    else:
        img.save(path, format="JPEG")
    return path


def _make_png(path: Path, dt: datetime | None, *, with_offset: bool = True, color=(50, 200, 50)) -> Path:
    img = Image.new("RGB", (8, 8), color)
    if dt is not None:
        img.save(path, format="PNG", exif=_exif_with_datetime(dt, with_offset=with_offset))
    else:
        img.save(path, format="PNG")
    return path


@pytest.fixture
def jpeg_factory(tmp_path):
    """Factory: jpeg_factory(name, dt, with_offset=True) → Path."""
    def _make(name: str, dt: datetime | None = None, *, with_offset: bool = True) -> Path:
        return _make_jpeg(tmp_path / name, dt, with_offset=with_offset)
    return _make


@pytest.fixture
def png_factory(tmp_path):
    def _make(name: str, dt: datetime | None = None, *, with_offset: bool = True) -> Path:
        return _make_png(tmp_path / name, dt, with_offset=with_offset)
    return _make


def _make_dng(path: Path, dt: datetime | None = None, *, with_gps: bool = False) -> Path:
    """Synthesize a tiny DNG (TIFF-based) with optional EXIF DateTimeOriginal.

    DNG is structurally a TIFF, which Pillow writes natively. exifread parses
    the same EXIF tags regardless of extension, enough to exercise RAW reads.
    """
    img = Image.new("RGB", (8, 8), (90, 110, 130))
    save_kwargs: dict = {"format": "TIFF"}
    if dt is not None:
        exif_dict: dict = {"0th": {}, "Exif": {}, "GPS": {}, "1st": {}, "thumbnail": None}
        s = dt.strftime("%Y:%m:%d %H:%M:%S").encode("ascii")
        exif_dict["Exif"][piexif.ExifIFD.DateTimeOriginal] = s
        if with_gps:
            exif_dict["GPS"] = {
                piexif.GPSIFD.GPSVersionID: (2, 0, 0, 0),
                piexif.GPSIFD.GPSLatitudeRef: b"N",
                piexif.GPSIFD.GPSLatitude: ((48, 1), (51, 1), (237600, 10000)),
                piexif.GPSIFD.GPSLongitudeRef: b"E",
                piexif.GPSIFD.GPSLongitude: ((2, 1), (21, 1), (79200, 10000)),
            }
        save_kwargs["exif"] = piexif.dump(exif_dict)
    img.save(path, **save_kwargs)
    return path


@pytest.fixture
def dng_factory(tmp_path):
    """Factory: dng_factory(name, dt=..., with_gps=False) → Path (a tiny RAW/DNG)."""
    def _make(name: str, dt: datetime | None = None, *, with_gps: bool = False) -> Path:
        return _make_dng(tmp_path / name, dt, with_gps=with_gps)
    return _make


@pytest.fixture
def heic_factory(tmp_path):
    """Factory for HEIC. Skips if pillow_heif is unavailable for writing."""
    if not _HEIF_AVAILABLE:
        pytest.skip("pillow_heif not installed")

    def _make(name: str, dt: datetime | None = None, *, with_offset: bool = True) -> Path:
        img = Image.new("RGB", (8, 8), (50, 50, 200))
        path = tmp_path / name
        kwargs = {"format": "HEIF"}
        if dt is not None:
            kwargs["exif"] = _exif_with_datetime(dt, with_offset=with_offset)
        try:
            img.save(path, **kwargs)
        except Exception as e:
            pytest.skip(f"HEIF save not supported in this pillow_heif build: {e}")
        return path
    return _make


@pytest.fixture
def sample_gpx(tmp_path):
    """A small GPX with three trkpt entries one minute apart in UTC."""
    path = tmp_path / "sample.gpx"
    path.write_text(
        """<?xml version="1.0" encoding="UTF-8"?>
<gpx xmlns="http://www.topografix.com/GPX/1/1" version="1.1" creator="gpsphototag-tests">
  <trk><name>sample</name><trkseg>
    <trkpt lat="48.8566" lon="2.3522"><ele>35</ele><time>2024-08-15T10:00:00Z</time></trkpt>
    <trkpt lat="48.8600" lon="2.3550"><ele>35</ele><time>2024-08-15T10:01:00Z</time></trkpt>
    <trkpt lat="48.8650" lon="2.3600"><ele>35</ele><time>2024-08-15T10:02:00Z</time></trkpt>
  </trkseg></trk>
</gpx>
""",
        encoding="utf-8",
    )
    return path


@pytest.fixture
def sample_records_json(tmp_path):
    """A Google Takeout-shaped Records.json (locations[])."""
    path = tmp_path / "Records.json"
    data = {
        "locations": [
            {"timestamp": "2024-08-15T09:00:00.000Z", "latitudeE7": 488566000, "longitudeE7": 23522000},
            {"timestamp": "2024-08-15T09:30:00.000Z", "latitudeE7": 488600000, "longitudeE7": 23550000},
            {"timestamp": "2024-08-15T10:00:00.000Z", "latitudeE7": 488700000, "longitudeE7": 23700000},
        ]
    }
    path.write_text(json.dumps(data), encoding="utf-8")
    return path


@pytest.fixture
def sample_timeline_json(tmp_path):
    """A Google Maps per-day Timeline JSON export."""
    path = tmp_path / "timeline-2024-08-15.json"
    data = {
        "timelineObjects": [
            {
                "placeVisit": {
                    "location": {"latitudeE7": 488566000, "longitudeE7": 23522000},
                    "duration": {
                        "startTimestamp": "2024-08-15T08:00:00.000Z",
                        "endTimestamp": "2024-08-15T08:30:00.000Z",
                    },
                }
            },
            {
                "activitySegment": {
                    "startLocation": {"latitudeE7": 488566000, "longitudeE7": 23522000},
                    "endLocation": {"latitudeE7": 488700000, "longitudeE7": 23700000},
                    "duration": {
                        "startTimestamp": "2024-08-15T08:45:00.000Z",
                        "endTimestamp": "2024-08-15T09:15:00.000Z",
                    },
                    "simplifiedRawPath": {
                        "points": [
                            {"latE7": 488600000, "lngE7": 23550000, "timestampMs": "1723712400000"},
                        ]
                    },
                }
            },
        ]
    }
    path.write_text(json.dumps(data), encoding="utf-8")
    return path


@pytest.fixture
def sample_semantic_timeline_json(tmp_path):
    """Google's 2024+ mobile Timeline export (semanticSegments)."""
    path = tmp_path / "Timeline.json"
    data = {
        "semanticSegments": [
            {
                "startTime": "2024-08-15T09:00:00.000Z",
                "endTime": "2024-08-15T09:10:00.000Z",
                "timelinePath": [
                    {"point": "48.8566°, 2.3522°", "time": "2024-08-15T09:01:00.000Z"},
                    {"point": "48.8600°, 2.3550°", "time": "2024-08-15T09:05:00.000Z"},
                ],
            },
            {
                "startTime": "2024-08-15T10:00:00.000Z",
                "endTime": "2024-08-15T10:04:00.000Z",
                "visit": {
                    "topCandidate": {"placeLocation": {"latLng": "48.8700°, 2.3700°"}},
                },
            },
            {
                "startTime": "2024-08-15T12:00:00.000Z",
                "endTime": "2024-08-15T12:30:00.000Z",
                "activity": {
                    "start": {"latLng": "48.8566°, 2.3522°"},
                    "end": {"latLng": "48.8900°, 2.4000°"},
                },
            },
        ],
        "rawSignals": [],
        "userLocationProfile": {},
    }
    path.write_text(json.dumps(data), encoding="utf-8")
    return path


@pytest.fixture
def sample_timeline_kml(tmp_path):
    """A Timeline KML export with one gx:Track."""
    path = tmp_path / "timeline-2024-08-15.kml"
    path.write_text(
        """<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2" xmlns:gx="http://www.google.com/kml/ext/2.2">
  <Document><Placemark><gx:Track>
    <when>2024-08-15T09:00:00Z</when>
    <when>2024-08-15T09:30:00Z</when>
    <gx:coord>2.3522 48.8566 35</gx:coord>
    <gx:coord>2.3550 48.8600 35</gx:coord>
  </gx:Track></Placemark></Document>
</kml>
""",
        encoding="utf-8",
    )
    return path


@pytest.fixture
def utc():
    return timezone.utc
