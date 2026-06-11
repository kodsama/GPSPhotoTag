"""Locator: exact match, linear interpolation, threshold, source precedence."""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from gpsphototag.locator import Locator
from gpsphototag.types import TimedPoint

UTC = timezone.utc


def _p(minutes: int, lat: float, lon: float) -> TimedPoint:
    return TimedPoint(time=datetime(2024, 1, 1, 10, minutes, 0, tzinfo=UTC), lat=lat, lon=lon)


def test_exact_match_returns_exact():
    loc = Locator([_p(0, 1.0, 2.0), _p(1, 1.1, 2.1)], [], max_time_diff_seconds=60)
    r = loc.locate(datetime(2024, 1, 1, 10, 0, 0, tzinfo=UTC))
    assert r is not None
    assert r.method == "exact"
    assert (r.lat, r.lon) == (1.0, 2.0)
    assert r.source == "gpx"


def test_interpolation_linear():
    loc = Locator([_p(0, 0.0, 0.0), _p(2, 2.0, 4.0)], [], max_time_diff_seconds=300)
    midpoint = datetime(2024, 1, 1, 10, 1, 0, tzinfo=UTC)
    r = loc.locate(midpoint)
    assert r is not None
    assert r.method == "interpolated"
    assert r.lat == pytest.approx(1.0)
    assert r.lon == pytest.approx(2.0)


def test_returns_none_when_outside_threshold():
    loc = Locator([_p(0, 0.0, 0.0), _p(2, 2.0, 2.0)], [], max_time_diff_seconds=10)
    far_ts = datetime(2024, 1, 1, 11, 0, 0, tzinfo=UTC)
    assert loc.locate(far_ts) is None


def test_returns_none_when_only_one_side_in_range():
    """A point in the past but nothing in the future — no extrapolation."""
    loc = Locator([_p(0, 1.0, 2.0)], [], max_time_diff_seconds=60)
    later = datetime(2024, 1, 1, 10, 0, 30, tzinfo=UTC)
    assert loc.locate(later) is None


def test_gpx_takes_precedence_over_google():
    gpx = [_p(0, 10.0, 20.0), _p(2, 12.0, 22.0)]
    google = [_p(0, 99.0, 99.0), _p(2, 88.0, 88.0)]
    loc = Locator(gpx, google, max_time_diff_seconds=300)
    r = loc.locate(datetime(2024, 1, 1, 10, 1, 0, tzinfo=UTC))
    assert r is not None
    assert r.source == "gpx"


def test_google_fallback_when_gpx_empty():
    google = [_p(0, 5.0, 6.0), _p(2, 7.0, 8.0)]
    loc = Locator([], google, max_time_diff_seconds=300)
    r = loc.locate(datetime(2024, 1, 1, 10, 1, 0, tzinfo=UTC))
    assert r is not None
    assert r.source == "google"


def test_naive_datetime_raises():
    loc = Locator([_p(0, 1.0, 2.0)], [], max_time_diff_seconds=10)
    with pytest.raises(ValueError):
        loc.locate(datetime(2024, 1, 1, 10, 0, 0))


def test_empty_sources_return_none():
    assert Locator([], [], 60).locate(datetime(2024, 1, 1, tzinfo=UTC)) is None


def test_unsorted_input_points_still_locate():
    """Locator must not silently mis-bisect when callers pass unsorted points."""
    pts = [_p(4, 9.0, 9.0), _p(0, 1.0, 2.0), _p(2, 5.0, 6.0)]
    loc = Locator(pts, [], max_time_diff_seconds=300)
    # Exact hit on the chronologically-last point: bisect on the unsorted list
    # lands past the end and finds nothing.
    r = loc.locate(datetime(2024, 1, 1, 10, 4, 0, tzinfo=UTC))
    assert r is not None
    assert r.method == "exact"
    assert r.lat == 9.0
