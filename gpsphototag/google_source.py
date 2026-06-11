"""Parse Google location-history sources into TimedPoints.

Four shapes are auto-detected:

1. **Takeout `Records.json`** — ``{"locations": [...]}`` with ``latitudeE7`` /
   ``longitudeE7`` and ``timestamp`` (RFC3339) or ``timestampMs`` (epoch ms).
2. **Timeline per-day JSON** — ``{"timelineObjects": [...]}`` with
   ``placeVisit``, ``activitySegment``, and optional ``simplifiedRawPath``.
3. **Mobile Timeline export (2024+)** — ``{"semanticSegments": [...]}`` with
   ``timelinePath`` points, ``visit`` place locations, and ``activity``
   start/end locations; coordinates are ``"lat°, lon°"`` strings.
4. **Timeline KML** — ``<gx:Track>`` with paired ``<when>`` and ``<gx:coord>``.
"""

from __future__ import annotations

import json
import logging
import xml.etree.ElementTree as ET
from collections.abc import Iterable
from datetime import datetime, timedelta, timezone
from pathlib import Path

from dateutil import parser as date_parser

from gpsphototag.types import TimedPoint

logger = logging.getLogger(__name__)

KML_NS = {"kml": "http://www.opengis.net/kml/2.2", "gx": "http://www.google.com/kml/ext/2.2"}

# A Timeline ``visit`` is a stationary stay with one constant location across its
# whole [startTime, endTime]. Emit that location periodically (not just at the
# endpoints) so a photo taken mid-stay can be bracketed by the locator, which
# requires two points within its time threshold. 120 s stays inside both the
# default 300 s threshold and looser settings.
_VISIT_SAMPLE_SECONDS = 120


def _parse_ts(value: str | int) -> datetime:
    """Parse Google timestamps (ISO-8601, or epoch ms as int/str) to UTC."""
    if isinstance(value, int) or (isinstance(value, str) and value.isdigit()):
        return datetime.fromtimestamp(int(value) / 1000.0, tz=timezone.utc)
    dt = date_parser.isoparse(value)
    return dt.astimezone(timezone.utc) if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def _e7(value: int | float) -> float:
    """Convert E7 (Google integer lat/lon) to decimal degrees."""
    return float(value) / 1e7


def _detect_json_shape(obj: dict) -> str:
    """Return 'records', 'timeline', or 'semantic' for a parsed JSON object."""
    if "locations" in obj and isinstance(obj["locations"], list):
        return "records"
    if "timelineObjects" in obj and isinstance(obj["timelineObjects"], list):
        return "timeline"
    if "semanticSegments" in obj and isinstance(obj["semanticSegments"], list):
        return "semantic"
    raise ValueError(
        "Unrecognized Google JSON shape "
        "(no 'locations', 'timelineObjects', or 'semanticSegments')"
    )


def _parse_latlng(value: str) -> tuple[float, float]:
    """Parse a Google ``"lat°, lon°"`` string into a (lat, lon) decimal pair."""
    lat_s, lon_s = value.split(",")
    return (
        float(lat_s.replace("°", "").strip()),
        float(lon_s.replace("°", "").strip()),
    )


def _parse_records(obj: dict) -> list[TimedPoint]:
    """Iterate ``locations[]`` from a Takeout Records.json."""
    points: list[TimedPoint] = []
    for entry in obj.get("locations", []):
        try:
            lat = _e7(entry["latitudeE7"])
            lon = _e7(entry["longitudeE7"])
            ts = entry.get("timestamp") or entry.get("timestampMs")
            if ts is None:
                continue
            points.append(TimedPoint(time=_parse_ts(ts), lat=lat, lon=lon))
        except (KeyError, ValueError, TypeError) as e:
            logger.debug("Skipping Records.json entry: %s", e)
    return points


def _parse_timeline(obj: dict) -> list[TimedPoint]:
    """Iterate ``timelineObjects[]`` from a per-day Timeline export."""
    points: list[TimedPoint] = []
    for entry in obj.get("timelineObjects", []):
        if "placeVisit" in entry:
            v = entry["placeVisit"]
            try:
                lat = _e7(v["location"]["latitudeE7"])
                lon = _e7(v["location"]["longitudeE7"])
                ts = v["duration"]["startTimestamp"]
                points.append(TimedPoint(time=_parse_ts(ts), lat=lat, lon=lon))
            except (KeyError, ValueError, TypeError):
                continue
        elif "activitySegment" in entry:
            s = entry["activitySegment"]
            dur = s.get("duration", {})
            try:
                start_ts = dur.get("startTimestamp")
                end_ts = dur.get("endTimestamp")
                if "startLocation" in s and start_ts:
                    points.append(TimedPoint(
                        time=_parse_ts(start_ts),
                        lat=_e7(s["startLocation"]["latitudeE7"]),
                        lon=_e7(s["startLocation"]["longitudeE7"]),
                    ))
                if "endLocation" in s and end_ts:
                    points.append(TimedPoint(
                        time=_parse_ts(end_ts),
                        lat=_e7(s["endLocation"]["latitudeE7"]),
                        lon=_e7(s["endLocation"]["longitudeE7"]),
                    ))
            except (KeyError, ValueError, TypeError):
                pass
            for pt in s.get("simplifiedRawPath", {}).get("points", []):
                try:
                    lat = _e7(pt.get("latE7", pt.get("latitudeE7")))
                    lon = _e7(pt.get("lngE7", pt.get("longitudeE7")))
                    ts = pt.get("timestamp") or pt.get("timestampMs")
                    if ts is None:
                        continue
                    points.append(TimedPoint(time=_parse_ts(ts), lat=lat, lon=lon))
                except (KeyError, ValueError, TypeError):
                    continue
    return points


def _visit_times(start: datetime | None, end: datetime | None) -> list[datetime]:
    """Sample timestamps across a visit's [start, end], inclusive, every
    ``_VISIT_SAMPLE_SECONDS``. Falls back to whichever endpoint(s) exist."""
    if start is None:
        return [end] if end is not None else []
    if end is None or end <= start:
        return [start]
    step = timedelta(seconds=_VISIT_SAMPLE_SECONDS)
    times: list[datetime] = []
    t = start
    while t < end:
        times.append(t)
        t += step
    times.append(end)
    return times


def _parse_semantic(obj: dict) -> list[TimedPoint]:
    """Iterate ``semanticSegments[]`` from a 2024+ mobile Timeline export."""
    points: list[TimedPoint] = []
    for seg in obj.get("semanticSegments", []):
        if "timelinePath" in seg:
            for pt in seg["timelinePath"]:
                try:
                    lat, lon = _parse_latlng(pt["point"])
                    points.append(TimedPoint(time=_parse_ts(pt["time"]), lat=lat, lon=lon))
                except (KeyError, ValueError, TypeError):
                    continue
        elif "visit" in seg:
            try:
                lat, lon = _parse_latlng(
                    seg["visit"]["topCandidate"]["placeLocation"]["latLng"]
                )
                start = _parse_ts(seg["startTime"]) if seg.get("startTime") else None
                end = _parse_ts(seg["endTime"]) if seg.get("endTime") else None
                for t in _visit_times(start, end):
                    points.append(TimedPoint(time=t, lat=lat, lon=lon))
            except (KeyError, ValueError, TypeError):
                continue
        elif "activity" in seg:
            act = seg["activity"]
            for end_key, ts_key in (("start", "startTime"), ("end", "endTime")):
                try:
                    lat, lon = _parse_latlng(act[end_key]["latLng"])
                    if seg.get(ts_key):
                        points.append(TimedPoint(time=_parse_ts(seg[ts_key]), lat=lat, lon=lon))
                except (KeyError, ValueError, TypeError):
                    continue
    return points


def _parse_kml(path: Path) -> list[TimedPoint]:
    """Parse a Timeline KML by pairing ``<when>`` and ``<gx:coord>`` siblings."""
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as e:
        logger.error("Failed to parse KML %s: %s", path, e)
        return []

    points: list[TimedPoint] = []
    for placemark in root.iter("{http://www.opengis.net/kml/2.2}Placemark"):
        for track in placemark.iter("{http://www.google.com/kml/ext/2.2}Track"):
            whens = [el.text for el in track.findall("kml:when", KML_NS) if el.text]
            coords = [el.text for el in track.findall("gx:coord", KML_NS) if el.text]
            for when, coord in zip(whens, coords, strict=False):
                try:
                    lon_s, lat_s, *_ = coord.strip().split()
                    points.append(TimedPoint(
                        time=_parse_ts(when),
                        lat=float(lat_s),
                        lon=float(lon_s),
                    ))
                except (ValueError, IndexError):
                    continue
        for point in placemark.iter("{http://www.opengis.net/kml/2.2}Point"):
            ts_el = placemark.find("kml:TimeStamp/kml:when", KML_NS)
            coord_el = point.find("kml:coordinates", KML_NS)
            if ts_el is not None and coord_el is not None and ts_el.text and coord_el.text:
                try:
                    lon_s, lat_s, *_ = coord_el.text.strip().split(",")
                    points.append(TimedPoint(
                        time=_parse_ts(ts_el.text),
                        lat=float(lat_s),
                        lon=float(lon_s),
                    ))
                except (ValueError, IndexError):
                    continue
    return points


def _load_one(path: Path) -> list[TimedPoint]:
    """Auto-detect a single file by content + extension and parse it."""
    suffix = path.suffix.lower()
    if suffix == ".kml":
        return _parse_kml(path)
    if suffix == ".json":
        try:
            obj = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as e:
            logger.error("Failed to parse JSON %s: %s", path, e)
            return []
        shape = _detect_json_shape(obj)
        if shape == "records":
            return _parse_records(obj)
        if shape == "semantic":
            return _parse_semantic(obj)
        return _parse_timeline(obj)
    logger.warning("Unknown maps-history extension %s for %s", suffix, path)
    return []


def load(paths: Iterable[Path]) -> list[TimedPoint]:
    """Load and merge all Google sources into a sorted UTC point list."""
    points: list[TimedPoint] = []
    for path in paths:
        n_before = len(points)
        points.extend(_load_one(path))
        logger.info("Loaded %d points from %s", len(points) - n_before, path)
    points.sort(key=lambda p: p.time)
    return points
