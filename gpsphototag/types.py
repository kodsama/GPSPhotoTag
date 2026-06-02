"""Shared data types for GPSPhotoTag."""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from pathlib import Path
from typing import Literal


@dataclass(frozen=True)
class TimedPoint:
    """A single timestamped GPS sample, normalized to UTC."""

    time: datetime
    lat: float
    lon: float


@dataclass(frozen=True)
class LocationResult:
    """Output of the Locator: the resolved location + provenance."""

    lat: float
    lon: float
    source: Literal["gpx", "google"]
    method: Literal["exact", "interpolated"]
    time_diff_seconds: float


class Status(str, Enum):
    """Per-photo outcome used by the display + summary."""

    TAGGED = "tagged"
    INTERPOLATED = "interpolated"
    REPLACED = "replaced"
    ALREADY_TAGGED = "already_tagged"
    NO_GPS = "no_gps"
    NO_TIMESTAMP = "no_timestamp"
    DATES_FIXED = "dates_fixed"
    DRY_RUN = "dry_run"
    ERROR = "error"


@dataclass
class PhotoRow:
    """A single row in the live status display + summary."""

    path: Path
    timestamp: datetime | None = None
    location: LocationResult | None = None
    status: Status = Status.NO_GPS
    detail: str = ""
    out_path: Path | None = None
    date_detail: str = ""


@dataclass
class RunSummary:
    """End-of-run aggregate counts and per-bucket file lists."""

    counts: dict[Status, int] = field(default_factory=dict)

    def record(self, status: Status) -> None:
        self.counts[status] = self.counts.get(status, 0) + 1

    @property
    def total(self) -> int:
        return sum(self.counts.values())
