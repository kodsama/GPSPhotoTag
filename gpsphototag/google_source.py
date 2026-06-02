"""Parse Google location-history sources into TimedPoints.

Three shapes are auto-detected:

1. **Takeout `Records.json`** — ``{"locations": [...]}`` with ``latitudeE7`` /
   ``longitudeE7`` and ``timestamp`` (RFC3339) or ``timestampMs`` (epoch ms).
2. **Timeline per-day JSON** — ``{"timelineObjects": [...]}`` with
   ``placeVisit``, ``activitySegment``, and optional ``simplifiedRawPath``.
3. **Timeline KML** — ``<gx:Track>`` with paired ``<when>`` and ``<gx:coord>``.
"""

from __future__ import annotations

import json
import logging
import xml.etree.ElementTree as ET
from collections.abc import Iterable
from datetime import datetime, timezone
from pathlib import Path

from dateutil import parser as date_parser

from gpsphototag.types import TimedPoint

logger = logging.getLogger(__name__)

KML_NS = {"kml": "http://www.opengis.net/kml/2.2", "gx": "http://www.google.com/kml/ext/2.2"}


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
    """Return 'records' or 'timeline' for a parsed JSON object."""
    if "locations" in obj and isinstance(obj["locations"], list):
        return "records"
    if "timelineObjects" in obj and isinstance(obj["timelineObjects"], list):
        return "timeline"
    raise ValueError("Unrecognized Google JSON shape (no 'locations' or 'timelineObjects')")


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
        return _parse_records(obj) if shape == "records" else _parse_timeline(obj)
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
