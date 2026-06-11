"""Google source auto-detect + parse for Records / Timeline JSON / KML."""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from gpsphototag import google_source


def test_records_json_parsing(sample_records_json):
    pts = google_source.load([sample_records_json])
    assert len(pts) == 3
    assert pts[0].time == datetime(2024, 8, 15, 9, 0, 0, tzinfo=timezone.utc)
    assert pts[0].lat == pytest.approx(48.8566)
    assert pts[0].lon == pytest.approx(2.3522)


def test_timeline_json_parsing(sample_timeline_json):
    pts = google_source.load([sample_timeline_json])
    # placeVisit start + activitySegment start + simplifiedRawPath point + activitySegment end
    assert len(pts) == 4
    times = [p.time for p in pts]
    assert times == sorted(times)


def test_semantic_timeline_json_parsing(sample_semantic_timeline_json):
    pts = google_source.load([sample_semantic_timeline_json])
    # 2 timelinePath points + visit densified @120s over 4min (10:00/10:02/10:04)
    # + activity (start+end) = 2 + 3 + 2
    assert len(pts) == 7
    times = [p.time for p in pts]
    assert times == sorted(times)
    assert pts[0].time == datetime(2024, 8, 15, 9, 1, 0, tzinfo=timezone.utc)
    assert pts[0].lat == pytest.approx(48.8566)
    assert pts[0].lon == pytest.approx(2.3522)


def test_semantic_visit_densified_to_cover_whole_stay(sample_semantic_timeline_json):
    """A visit emits its constant location periodically so a mid-visit
    timestamp can be bracketed (not just at start/end)."""
    pts = google_source.load([sample_semantic_timeline_json])
    visit_pts = [p for p in pts if p.lat == pytest.approx(48.8700)]
    assert [p.time for p in visit_pts] == [
        datetime(2024, 8, 15, 10, 0, 0, tzinfo=timezone.utc),
        datetime(2024, 8, 15, 10, 2, 0, tzinfo=timezone.utc),
        datetime(2024, 8, 15, 10, 4, 0, tzinfo=timezone.utc),
    ]


def test_timeline_kml_parsing(sample_timeline_kml):
    pts = google_source.load([sample_timeline_kml])
    assert len(pts) == 2
    assert pts[0].time == datetime(2024, 8, 15, 9, 0, 0, tzinfo=timezone.utc)
    assert pts[0].lat == pytest.approx(48.8566)


def test_auto_detect_merges_multiple_sources(sample_records_json, sample_timeline_kml):
    pts = google_source.load([sample_records_json, sample_timeline_kml])
    assert len(pts) == 3 + 2


def test_invalid_json_returns_empty(tmp_path, caplog):
    bad = tmp_path / "bad.json"
    bad.write_text("{not json", encoding="utf-8")
    with caplog.at_level("ERROR"):
        pts = google_source.load([bad])
    assert pts == []


def test_unknown_json_shape_logs_and_skips(tmp_path):
    f = tmp_path / "weird.json"
    f.write_text('{"hello": "world"}', encoding="utf-8")
    with pytest.raises(ValueError):
        google_source._detect_json_shape({"hello": "world"})


def test_records_with_legacy_timestamp_ms(tmp_path):
    f = tmp_path / "Records.json"
    f.write_text(
        '{"locations":[{"latitudeE7":488566000,"longitudeE7":23522000,"timestampMs":"1723712400000"}]}',
        encoding="utf-8",
    )
    pts = google_source.load([f])
    assert len(pts) == 1
    assert pts[0].time.tzinfo is timezone.utc
