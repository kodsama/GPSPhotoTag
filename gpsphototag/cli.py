#!/usr/bin/env python3
"""Command-line entry point for ``gpsphototag``.

Wires argparse → collectors → sources → Locator → Tagger → display. Keeps
top-level functions short and named so they can be swapped or reused as a
library.
"""

from __future__ import annotations

# Allow running this file directly from source (``./gpsphototag/cli.py``): put the
# project root on sys.path so the ``from gpsphototag import ...`` lines below
# resolve. Skipped on normal package import (where __package__ == "gpsphototag").
if __name__ == "__main__" and __package__ in (None, ""):
    import pathlib
    import sys as _bootstrap_sys

    _bootstrap_sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

import argparse
import logging
from datetime import tzinfo
from pathlib import Path

from rich.console import Console
from rich.logging import RichHandler

from gpsphototag import __version__, google_source, gpx_source
from gpsphototag.collectors import GPX_EXTS, MAPS_EXTS, PHOTO_EXTS, collect_paths
from gpsphototag.display import StatusDisplay
from gpsphototag.locator import Locator
from gpsphototag.tagger import Tagger, TaggerOptions, copy_unmodified_to_out
from gpsphototag.types import Status

logger = logging.getLogger("gpsphototag")


def build_parser() -> argparse.ArgumentParser:
    """Construct the argparse parser. Kept separate so tests can exercise it."""
    p = argparse.ArgumentParser(
        prog="gpsphototag",
        description="Tag photos with GPS EXIF from GPX tracks or Google location history.",
    )
    p.add_argument("--photo", "-p", action="append", nargs="+", required=True, metavar="PATH",
                   help="photo file, glob, or directory (repeatable; recursive on dirs)")
    p.add_argument("--gps", "-g", action="append", nargs="+", metavar="PATH",
                   help="GPX file, glob, or directory (repeatable)")
    p.add_argument("--maps-history", "-m", action="append", nargs="+", metavar="PATH",
                   help="Google Takeout Records.json and/or Timeline JSON/KML (repeatable)")
    p.add_argument("--out", "-o", type=Path, metavar="DIR",
                   help="output directory; if omitted, --overwrite is required")
    p.add_argument("--overwrite", action="store_true",
                   help="modify originals in place (required when --out is absent)")
    p.add_argument("--replace", action="store_true",
                   help="overwrite existing GPS bytes (otherwise such photos are skipped)")
    p.add_argument("--raw-mode", choices=("auto", "sidecar", "embed"), default="auto",
                   help="how to write GPS for RAW files: 'auto' (default) embeds into the RAW "
                        "via exiftool when available, else writes an XMP sidecar; 'sidecar' "
                        "always writes an XMP sidecar; 'embed' forces exiftool")
    p.add_argument("--fix-dates", choices=("exif", "file"), default=None,
                   help="also fix dates: 'exif' sets the file's created/modified date "
                        "from the EXIF timestamp; 'file' writes the EXIF DateTimeOriginal "
                        "from the file's created date")
    p.add_argument("--max-time-diff", type=float, default=300.0, metavar="SECONDS",
                   help="max gap between photo time and GPS point(s) [default: 300]")
    p.add_argument("--timezone", default=None, metavar="TZ",
                   help="IANA tz used when EXIF lacks OffsetTimeOriginal (default: system local)")
    p.add_argument("--dry-run", action="store_true",
                   help="locate + report only; write nothing")
    p.add_argument("--verbose", "-v", action="store_true",
                   help="DEBUG console logging")
    p.add_argument("--log-file", type=Path, metavar="PATH",
                   help="also write INFO+ logs to this file")
    p.add_argument("--version", action="version", version=f"gpsphototag {__version__}")
    return p


def setup_logging(verbose: bool, log_file: Path | None) -> None:
    """Configure root logger: RichHandler on console, optional FileHandler."""
    level = logging.DEBUG if verbose else logging.INFO
    root = logging.getLogger()
    for h in list(root.handlers):
        root.removeHandler(h)
    root.setLevel(level)
    root.addHandler(RichHandler(level=level, show_time=False, show_path=False, markup=True))
    if log_file is not None:
        fh = logging.FileHandler(log_file, mode="a", encoding="utf-8")
        fh.setLevel(logging.INFO)
        fh.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s %(message)s"))
        root.addHandler(fh)

    # exifread logs "File format not recognized." at WARNING for RAW containers
    # it can't parse (e.g. .RAF); GPSPhotoTag handles those via the exiftool
    # fallback, so silence that noise unless the user asked for --verbose.
    logging.getLogger("exifread").setLevel(logging.DEBUG if verbose else logging.ERROR)


def resolve_timezone(name: str | None) -> tzinfo:
    """Resolve --timezone (or default to system local) into a tzinfo."""
    if name is None:
        from tzlocal import get_localzone
        return get_localzone()
    from zoneinfo import ZoneInfo
    return ZoneInfo(name)


def validate_destination(args: argparse.Namespace) -> str | None:
    """Return an error string if the destination flags are invalid."""
    if args.dry_run:
        return None
    if args.out is not None and args.overwrite:
        return "--out and --overwrite are mutually exclusive."
    if args.replace and args.out is None and not args.overwrite:
        return "--replace requires --out or --overwrite."
    if args.out is None and not args.overwrite:
        return "Specify --out DIR or --overwrite to allow modifying photos."
    return None


def main(argv: list[str] | None = None) -> int:
    """CLI entry point. Returns a process exit code."""
    parser = build_parser()
    args = parser.parse_args(argv)
    setup_logging(args.verbose, args.log_file)

    err = validate_destination(args)
    if err:
        parser.error(err)

    photos = collect_paths(args.photo, PHOTO_EXTS)
    if not photos:
        logger.error("No photos matched --photo arguments.")
        return 1
    logger.info("Resolved %d photo(s)", len(photos))

    gpx_paths = collect_paths(args.gps, GPX_EXTS)
    maps_paths = collect_paths(args.maps_history, MAPS_EXTS)
    if not gpx_paths and not maps_paths:
        logger.warning("No GPS sources provided; only existing tags will be reported.")

    gpx_points = gpx_source.load(gpx_paths)
    google_points = google_source.load(maps_paths)
    logger.info("Loaded %d GPX point(s), %d Google point(s)", len(gpx_points), len(google_points))

    fallback_tz = resolve_timezone(args.timezone)
    locator = Locator(gpx_points, google_points, max_time_diff_seconds=args.max_time_diff)

    try:
        opts = TaggerOptions(
            out_dir=args.out, overwrite=args.overwrite, replace=args.replace,
            dry_run=args.dry_run, fallback_tz=fallback_tz, raw_mode=args.raw_mode,
            fix_dates=args.fix_dates,
        )
    except ValueError as e:
        parser.error(str(e))

    if args.raw_mode == "embed":
        from gpsphototag.raw_writer import exiftool_available
        if not exiftool_available():
            parser.error("--raw-mode embed requires `exiftool` on PATH.")

    display = StatusDisplay(console=Console(), root=Path.cwd())
    Tagger(locator, opts, display).run(photos)

    if opts.out_dir is not None and not opts.dry_run:
        copy_unmodified_to_out(photos, opts.out_dir, results=[])

    display.print_summary()
    if display.summary.counts.get(Status.ERROR, 0) > 0:
        return 2
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
