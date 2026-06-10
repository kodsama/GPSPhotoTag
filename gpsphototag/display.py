"""Live terminal status table plus end-of-run summary.

Uses ``rich`` for color/columns. The display is a thin wrapper around a
``rich.table.Table`` driven row-by-row from the Tagger.
"""

from __future__ import annotations

from collections.abc import Iterator
from pathlib import Path

from rich.console import Console
from rich.panel import Panel
from rich.table import Table

from gpsphototag.types import LocationResult, PhotoRow, RunSummary, Status

STATUS_STYLE: dict[Status, str] = {
    Status.TAGGED: "bold green",
    Status.INTERPOLATED: "green",
    Status.REPLACED: "yellow",
    Status.ALREADY_TAGGED: "yellow dim",
    Status.NO_GPS: "red",
    Status.NO_TIMESTAMP: "red dim",
    Status.DATES_FIXED: "green",
    Status.DRY_RUN: "cyan",
    Status.ERROR: "magenta",
}


def format_coords(loc: LocationResult | None) -> str:
    """Render coords as ``lat, lon (source/method)`` or em-dash if missing."""
    if loc is None:
        return "—"
    return f"{loc.lat:.5f}, {loc.lon:.5f} ({loc.source}/{loc.method})"


def format_time(row: PhotoRow) -> str:
    """Render the row's timestamp with offset, or an em-dash if missing."""
    return row.timestamp.strftime("%Y-%m-%d %H:%M:%S %z") if row.timestamp else "—"


def format_path(path: Path, root: Path | None = None) -> str:
    """Shorten path display: relative to ``root`` when possible."""
    if root is not None:
        try:
            return str(path.relative_to(root))
        except ValueError:
            pass
    return path.name


class StatusDisplay:
    """Streaming table printer. Each ``add(row)`` call prints one styled line."""

    def __init__(self, console: Console | None = None, root: Path | None = None) -> None:
        self.console = console or Console()
        self.root = root
        self.summary = RunSummary()
        self._printed_header = False

    def _print_header(self) -> None:
        table = Table.grid(padding=(0, 2))
        for col in ("Photo", "Time", "Source", "Coords", "Status"):
            table.add_column(col, style="bold")
        table.add_row(
            "[bold]Photo[/bold]", "[bold]Time[/bold]", "[bold]Source[/bold]",
            "[bold]Coords[/bold]", "[bold]Status[/bold]",
        )
        self.console.print(table)
        self.console.print("[dim]" + "─" * 80 + "[/dim]")
        self._printed_header = True

    def add(self, row: PhotoRow) -> None:
        """Print one styled row and update the running summary."""
        if not self._printed_header:
            self._print_header()
        self.summary.record(row.status)
        style = STATUS_STYLE.get(row.status, "white")
        coords = format_coords(row.location)
        source = row.location.source if row.location else "—"
        notes = "; ".join(n for n in (row.detail, row.date_detail) if n)
        detail = f" [dim]{notes}[/dim]" if notes else ""
        self.console.print(
            f"{format_path(row.path, self.root)}  "
            f"[dim]{format_time(row)}[/dim]  "
            f"{source}  "
            f"{coords}  "
            f"[{style}]{row.status.value}[/{style}]{detail}"
        )

    def render_summary(self) -> Panel:
        """Build (but do not print) the final summary panel."""
        rows = "\n".join(
            f"[{STATUS_STYLE.get(s, 'white')}]{s.value:18}[/] {n}"
            for s, n in sorted(self.summary.counts.items(), key=lambda kv: kv[0].value)
        ) or "[dim](no photos)[/dim]"
        return Panel(rows + f"\n[bold]total[/bold]              {self.summary.total}",
                     title="GPSPhotoTag — summary", expand=False)

    def print_summary(self) -> None:
        """Print the final summary panel to the console."""
        self.console.print(self.render_summary())

    def __iter__(self) -> Iterator[tuple[Status, int]]:
        """Iterate ``(status, count)`` pairs from the run summary."""
        return iter(self.summary.counts.items())
