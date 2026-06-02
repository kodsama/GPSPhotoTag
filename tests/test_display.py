"""Display formatting and summary counts."""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

from rich.console import Console

from gpsphototag.display import StatusDisplay, format_coords, format_time
from gpsphototag.types import LocationResult, PhotoRow, Status


def test_format_coords_with_location():
    loc = LocationResult(48.8566, 2.3522, "gpx", "exact", 0.0)
    assert "48.85660" in format_coords(loc)
    assert "gpx/exact" in format_coords(loc)


def test_format_coords_none():
    assert format_coords(None) == "—"


def test_format_time_none():
    row = PhotoRow(path=Path("x.jpg"))
    assert format_time(row) == "—"


def test_summary_counts_increment_per_row(tmp_path):
    # Capture rich output to a string to avoid noisy stdout in tests.
    console = Console(file=open(tmp_path / "out.txt", "w"), force_terminal=False, width=120)
    disp = StatusDisplay(console=console)
    row1 = PhotoRow(path=tmp_path / "a.jpg", status=Status.TAGGED,
                    timestamp=datetime(2024, 1, 1, tzinfo=timezone.utc),
                    location=LocationResult(1.0, 2.0, "gpx", "exact", 0.0))
    row2 = PhotoRow(path=tmp_path / "b.jpg", status=Status.NO_GPS)
    disp.add(row1)
    disp.add(row2)
    assert disp.summary.counts[Status.TAGGED] == 1
    assert disp.summary.counts[Status.NO_GPS] == 1
    assert disp.summary.total == 2
