"""GPX parsing → sorted UTC TimedPoint list."""

from __future__ import annotations

from datetime import datetime, timezone

from gpsphototag import gpx_source


def test_load_returns_sorted_utc_points(sample_gpx):
    points = gpx_source.load([sample_gpx])
    assert len(points) == 3
    times = [p.time for p in points]
    assert times == sorted(times)
    assert all(p.time.tzinfo is timezone.utc for p in points)
    assert points[0].time == datetime(2024, 8, 15, 10, 0, 0, tzinfo=timezone.utc)
    assert points[0].lat == 48.8566 and points[0].lon == 2.3522


def test_load_merges_multiple_files(sample_gpx, tmp_path):
    second = tmp_path / "second.gpx"
    second.write_text(
        """<?xml version="1.0" encoding="UTF-8"?>
<gpx xmlns="http://www.topografix.com/GPX/1/1" version="1.1" creator="t">
  <trk><trkseg>
    <trkpt lat="10.0" lon="20.0"><time>2024-08-15T09:00:00Z</time></trkpt>
  </trkseg></trk>
</gpx>
""",
        encoding="utf-8",
    )
    points = gpx_source.load([sample_gpx, second])
    assert len(points) == 4
    assert points[0].time == datetime(2024, 8, 15, 9, 0, 0, tzinfo=timezone.utc)


def test_load_invalid_file_does_not_crash(tmp_path, caplog):
    bad = tmp_path / "bad.gpx"
    bad.write_text("not gpx content", encoding="utf-8")
    with caplog.at_level("ERROR"):
        points = gpx_source.load([bad])
    assert points == []
    assert any("Failed to parse" in r.message for r in caplog.records)


def test_load_skips_pointless_timestamps(tmp_path, caplog):
    f = tmp_path / "notime.gpx"
    f.write_text(
        """<?xml version="1.0" encoding="UTF-8"?>
<gpx xmlns="http://www.topografix.com/GPX/1/1" version="1.1" creator="t">
  <trk><trkseg>
    <trkpt lat="1.0" lon="2.0"/>
    <trkpt lat="3.0" lon="4.0"><time>2024-08-15T10:00:00Z</time></trkpt>
  </trkseg></trk>
</gpx>
""",
        encoding="utf-8",
    )
    with caplog.at_level("WARNING"):
        points = gpx_source.load([f])
    assert len(points) == 1
    assert any("without timestamps" in r.message for r in caplog.records)
