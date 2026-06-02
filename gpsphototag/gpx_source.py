"""Parse GPX files into a time-sorted list of TimedPoint (UTC)."""

from __future__ import annotations

import logging
from collections.abc import Iterable
from datetime import timezone
from pathlib import Path

import gpxpy

from gpsphototag.types import TimedPoint

logger = logging.getLogger(__name__)


def load(paths: Iterable[Path]) -> list[TimedPoint]:
    """Parse one or more GPX files and return all trackpoints sorted by UTC time.

    Points without a timestamp are skipped (warning logged once per file).
    """
    points: list[TimedPoint] = []
    for path in paths:
        try:
            with path.open("r", encoding="utf-8") as fh:
                gpx = gpxpy.parse(fh)
        except Exception as e:
            logger.error("Failed to parse GPX %s: %s", path, e)
            continue

        n_skipped = 0
        for track in gpx.tracks:
            for segment in track.segments:
                for pt in segment.points:
                    if pt.time is None:
                        n_skipped += 1
                        continue
                    t = pt.time.astimezone(timezone.utc) if pt.time.tzinfo else pt.time.replace(tzinfo=timezone.utc)
                    points.append(TimedPoint(time=t, lat=pt.latitude, lon=pt.longitude))
        for route in gpx.routes:
            for pt in route.points:
                if pt.time is None:
                    n_skipped += 1
                    continue
                t = pt.time.astimezone(timezone.utc) if pt.time.tzinfo else pt.time.replace(tzinfo=timezone.utc)
                points.append(TimedPoint(time=t, lat=pt.latitude, lon=pt.longitude))
        if n_skipped:
            logger.warning("%s: %d points without timestamps skipped", path, n_skipped)
        logger.info("Loaded %d points from %s", len(points), path)

    points.sort(key=lambda p: p.time)
    return points
