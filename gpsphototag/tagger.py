"""Per-photo orchestration: timestamp → locate → write → row.

Honors ``--out`` / ``--overwrite`` / ``--replace`` / ``--dry-run``. Errors on
one photo are isolated; we still emit a row and continue.
"""

from __future__ import annotations

import logging
import shutil
from dataclasses import dataclass
from datetime import tzinfo
from pathlib import Path

from gpsphototag import dates, raw_writer
from gpsphototag import exif as exif_mod
from gpsphototag.collectors import RAW_EXTS
from gpsphototag.display import StatusDisplay
from gpsphototag.locator import Locator
from gpsphototag.types import PhotoRow, Status

logger = logging.getLogger(__name__)


@dataclass
class TaggerOptions:
    """Run-level switches passed from the CLI."""

    out_dir: Path | None = None     # write outputs here (preserves originals)
    overwrite: bool = False          # allow modifying originals in place
    replace: bool = False            # overwrite existing GPS bytes
    dry_run: bool = False            # locate + report, write nothing
    fallback_tz: tzinfo | None = None  # used when EXIF lacks OffsetTimeOriginal
    raw_mode: str = "auto"           # "auto" | "sidecar" | "embed" (RAW files only)
    fix_dates: str | None = None     # None | "exif" (file←EXIF) | "file" (EXIF←file)

    def __post_init__(self) -> None:
        if self.out_dir is None and not self.overwrite and not self.dry_run:
            raise ValueError("Pass --out DIR or --overwrite (or --dry-run).")
        if self.out_dir is not None and self.overwrite:
            raise ValueError("--out and --overwrite are mutually exclusive.")
        if self.replace and self.out_dir is None and not self.overwrite and not self.dry_run:
            raise ValueError("--replace requires --out or --overwrite.")
        if self.raw_mode not in ("auto", "sidecar", "embed"):
            raise ValueError(f"raw_mode must be 'auto', 'sidecar', or 'embed', got {self.raw_mode!r}")
        if self.fix_dates not in (None, "exif", "file"):
            raise ValueError(f"fix_dates must be 'exif', 'file', or None, got {self.fix_dates!r}")


def _dest_for(photo: Path, opts: TaggerOptions) -> Path:
    """Resolve the output path for a single photo per the CLI options."""
    if opts.out_dir is None:
        return photo
    opts.out_dir.mkdir(parents=True, exist_ok=True)
    return opts.out_dir / photo.name


class Tagger:
    """Drive a Locator + EXIF writer over a list of photos."""

    def __init__(self, locator: Locator, options: TaggerOptions, display: StatusDisplay) -> None:
        self.locator = locator
        self.opts = options
        self.display = display

    def run(self, photos: list[Path]) -> StatusDisplay:
        """Tag every photo in ``photos``; return the populated display/summary."""
        for photo in photos:
            row = self._process(photo)
            self.display.add(row)
        return self.display

    def _process(self, photo: Path) -> PhotoRow:
        """Locate, write GPS, and/or fix dates for one photo (errors isolated)."""
        try:
            ts = exif_mod.read_timestamp(photo, fallback_tz=self.opts.fallback_tz)
        except Exception as e:
            logger.exception("EXIF read failed for %s", photo)
            return PhotoRow(path=photo, status=Status.ERROR, detail=str(e))

        already = exif_mod.has_gps(photo)
        gps_active = self.locator.has_points
        loc = self.locator.locate(ts) if ts is not None else None
        want_gps = loc is not None and (not already or self.opts.replace)

        if self.opts.dry_run:
            return self._dry_row(photo, ts, loc, want_gps, already, gps_active)
        return self._write(photo, ts, loc, already, gps_active, want_gps)

    def _plan_file_mode_dt(self, photo: Path):
        """For ``--fix-dates file``: the file's creation date to write into EXIF."""
        if self.opts.fix_dates != "file":
            return None, ""
        if (photo.suffix.lower() in RAW_EXTS
                and raw_writer.resolve_raw_mode(self.opts.raw_mode) != "embed"):
            return None, "file→exif skipped (RAW datetime needs exiftool / --raw-mode embed)"
        return dates.read_file_created(photo), ""

    def _write(self, photo, ts, loc, already, gps_active, want_gps) -> PhotoRow:
        """Perform the writes decided by ``_process`` and build the result row."""
        opts = self.opts
        dst = _dest_for(photo, opts)
        dt_for_exif, date_detail = self._plan_file_mode_dt(photo)
        need_content = want_gps or dt_for_exif is not None

        try:
            if need_content:
                exif_mod.apply_exif(photo, dst, gps=(loc.lat, loc.lon) if want_gps else None,
                                    dt=dt_for_exif, raw_mode=opts.raw_mode)
            elif opts.out_dir is not None and opts.fix_dates is not None:
                self._ensure_copy(photo, dst)
        except Exception as e:
            logger.exception("Write failed for %s → %s", photo, dst)
            return PhotoRow(path=photo, timestamp=ts, location=loc,
                            status=Status.ERROR, detail=str(e))

        date_done = dt_for_exif is not None
        if date_done:
            date_detail = f"exif←file ({dt_for_exif:%Y-%m-%d %H:%M})"
        elif opts.fix_dates == "exif":
            target = dst if opts.out_dir is not None else photo
            date_done, date_detail = self._set_file_dates(target, ts)

        status, detail = self._status(want_gps, gps_active, already, loc, ts, date_done)
        out_path = dst if (need_content or date_done) else None
        return PhotoRow(path=photo, timestamp=ts, location=loc, status=status,
                        detail=detail, date_detail=date_detail, out_path=out_path)

    def _set_file_dates(self, target: Path, ts):
        """Apply ``--fix-dates exif``: set ``target``'s dates from EXIF ``ts``."""
        if ts is None:
            return False, "file←exif skipped (no EXIF timestamp)"
        try:
            birth = dates.set_file_dates(target, ts)
        except Exception as e:  # pragma: no cover - defensive
            logger.exception("Setting file dates failed for %s", target)
            return False, f"date set failed: {e}"
        suffix = "" if birth else " (mtime only)"
        return True, f"file←exif ({ts:%Y-%m-%d %H:%M}){suffix}"

    def _status(self, want_gps, gps_active, already, loc, ts, date_done):
        """Pick the single row status, GPS outcome taking precedence over dates."""
        if want_gps:
            if already:
                return Status.REPLACED, ""
            return (Status.INTERPOLATED if loc.method == "interpolated"
                    else Status.TAGGED), ""
        if gps_active:
            if already and not self.opts.replace and loc is not None:
                return Status.ALREADY_TAGGED, "use --replace to overwrite"
            if ts is None:
                return Status.NO_TIMESTAMP, "missing DateTimeOriginal"
            return Status.NO_GPS, "no GPS within threshold"
        if date_done:
            return Status.DATES_FIXED, ""
        if ts is None and self.opts.fix_dates != "file":
            return Status.NO_TIMESTAMP, "missing DateTimeOriginal"
        return Status.NO_GPS, "no GPS source"

    @staticmethod
    def _ensure_copy(photo: Path, dst: Path) -> None:
        """Copy ``photo`` to ``dst`` if absent (for date-only writes into --out)."""
        dst.parent.mkdir(parents=True, exist_ok=True)
        if not dst.exists():
            shutil.copy2(photo, dst)

    def _dry_row(self, photo, ts, loc, want_gps, already, gps_active) -> PhotoRow:
        """Build a no-write DRY_RUN row describing the intended actions."""
        plans: list[str] = []
        if want_gps:
            plans.append("write GPS")
        elif gps_active and already:
            plans.append("skip (already tagged)")
        elif gps_active:
            plans.append("no GPS match")
        if self.opts.fix_dates == "exif":
            plans.append("file date ← EXIF" if ts else "fix-dates exif: no EXIF ts")
        elif self.opts.fix_dates == "file":
            plans.append("EXIF ← file date")
        return PhotoRow(path=photo, timestamp=ts, location=loc,
                        status=Status.DRY_RUN, date_detail=", ".join(plans))


def copy_unmodified_to_out(photos: list[Path], out_dir: Path, results: list[PhotoRow]) -> None:
    """Mirror photos we did NOT modify (no GPS / already tagged) into ``out_dir``.

    Useful when ``--out`` is set — keeps the output directory complete so the
    user can grab everything from one place.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    touched = {r.path for r in results if r.out_path is not None}
    for p in photos:
        if p in touched:
            continue
        dst = out_dir / p.name
        if not dst.exists():
            shutil.copy2(p, dst)
