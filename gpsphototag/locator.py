"""Pick a GPS coordinate for a photo timestamp.

Strategy: prefer GPX over Google. Within each source, return an exact match
when one is within ~1 s, else linearly interpolate between two bracketing
points if both are within ``max_time_diff``. No extrapolation.
"""

from __future__ import annotations

import logging
from bisect import bisect_left
from collections.abc import Sequence
from datetime import datetime

from gpsphototag.types import LocationResult, TimedPoint

logger = logging.getLogger(__name__)

EXACT_TOLERANCE_S = 1.0


class Locator:
    """Composite GPS source. GPX takes precedence over Google."""

    def __init__(
        self,
        gpx_points: Sequence[TimedPoint],
        google_points: Sequence[TimedPoint],
        max_time_diff_seconds: float = 300.0,
    ) -> None:
        self._gpx = list(gpx_points)
        self._google = list(google_points)
        self._gpx_times = [p.time for p in self._gpx]
        self._google_times = [p.time for p in self._google]
        self._max = float(max_time_diff_seconds)

    @property
    def has_points(self) -> bool:
        """True if any GPS source (GPX or Google) supplied points."""
        return bool(self._gpx or self._google)

    def locate(self, ts: datetime) -> LocationResult | None:
        """Resolve a UTC-aware timestamp to a LocationResult, or None."""
        if ts.tzinfo is None:
            raise ValueError("Locator.locate requires a tz-aware datetime")
        result = self._search(self._gpx, self._gpx_times, ts, source="gpx")
        if result is not None:
            return result
        return self._search(self._google, self._google_times, ts, source="google")

    def _search(
        self,
        points: list[TimedPoint],
        times: list[datetime],
        ts: datetime,
        *,
        source: str,
    ) -> LocationResult | None:
        if not points:
            return None
        i = bisect_left(times, ts)
        candidates: list[TimedPoint] = []
        if i > 0:
            candidates.append(points[i - 1])
        if i < len(points):
            candidates.append(points[i])

        # Exact match within tolerance.
        for p in candidates:
            diff = abs((p.time - ts).total_seconds())
            if diff <= EXACT_TOLERANCE_S:
                return LocationResult(
                    lat=p.lat, lon=p.lon, source=source,  # type: ignore[arg-type]
                    method="exact", time_diff_seconds=diff,
                )

        # Bracketed interpolation.
        if i > 0 and i < len(points):
            prev, nxt = points[i - 1], points[i]
            dt_prev = (ts - prev.time).total_seconds()
            dt_next = (nxt.time - ts).total_seconds()
            if dt_prev <= self._max and dt_next <= self._max:
                span = (nxt.time - prev.time).total_seconds()
                alpha = dt_prev / span if span > 0 else 0.0
                lat = prev.lat + alpha * (nxt.lat - prev.lat)
                lon = prev.lon + alpha * (nxt.lon - prev.lon)
                return LocationResult(
                    lat=lat, lon=lon, source=source,  # type: ignore[arg-type]
                    method="interpolated",
                    time_diff_seconds=min(dt_prev, dt_next),
                )

        return None
