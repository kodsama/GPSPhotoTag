"""Date/time helpers: EXIF string parsing + filesystem timestamps.

The EXIF parsers (``parse_exif_offset``, ``parse_exif_datetime``) are shared by
``exif`` and ``raw_writer``. The filesystem half implements ``--fix-dates``,
with two directions driven by the CLI:

* ``--fix-dates exif`` — set the file's dates *from* its EXIF timestamp
  (``set_file_dates``).
* ``--fix-dates file`` — read the file's creation date (``read_file_created``)
  to later write *into* EXIF.

Setting the modified/accessed time is portable via ``os.utime``. Setting the
macOS "Date Created" (birthtime) is best-effort via the ``SetFile`` binary
(part of Xcode command-line tools); when it's unavailable we warn and leave
birthtime unchanged.
"""

from __future__ import annotations

import logging
import os
import platform
import subprocess
from datetime import datetime, timedelta, timezone, tzinfo
from pathlib import Path
from shutil import which

logger = logging.getLogger(__name__)


def parse_exif_offset(value: str) -> tzinfo | None:
    """Parse an EXIF UTC-offset string like ``+02:00`` into a tzinfo.

    ``Z`` / ``+00:00`` / ``-00:00`` mean UTC. Returns None for malformed input
    so callers can fall back to a default timezone.
    """
    s = value.strip()
    if not s or s in ("Z", "+00:00", "-00:00"):
        return timezone.utc
    try:
        sign = 1 if s[0] == "+" else -1
        hh, mm = s[1:].split(":")
        return timezone(sign * timedelta(hours=int(hh), minutes=int(mm)))
    except (ValueError, IndexError):
        return None


def parse_exif_datetime(raw: str, offset: str | None, fallback_tz: tzinfo) -> datetime | None:
    """Parse an EXIF ``YYYY:MM:DD HH:MM:SS`` string into a tz-aware datetime.

    ``offset`` (e.g. ``+02:00``) is applied when present and valid; otherwise
    ``fallback_tz``. Returns None when the datetime itself is unparseable.
    """
    try:
        dt = datetime.strptime(raw.strip(), "%Y:%m:%d %H:%M:%S")
    except ValueError:
        return None
    tz = parse_exif_offset(offset) if offset else None
    return dt.replace(tzinfo=tz or fallback_tz)


def read_file_created(path: Path) -> datetime:
    """Return the file's creation date as a tz-aware (local) datetime.

    Uses ``st_birthtime`` where the platform provides it (macOS, some BSDs),
    falling back to ``st_mtime`` elsewhere.
    """
    st = path.stat()
    epoch = getattr(st, "st_birthtime", None)
    if epoch is None:
        epoch = st.st_mtime
    return datetime.fromtimestamp(epoch).astimezone()


def setfile_available() -> bool:
    """True if the macOS ``SetFile`` binary is on PATH (sets birthtime)."""
    return which("SetFile") is not None


def set_file_dates(path: Path, dt: datetime) -> bool:
    """Set ``path``'s modified/accessed time to ``dt``; try birthtime too.

    Returns True if the creation date (birthtime) was also set. The
    modified/accessed time is always set. ``dt`` must be tz-aware.
    """
    epoch = dt.timestamp()
    os.utime(path, (epoch, epoch))

    if platform.system() != "Darwin":
        return False
    if not setfile_available():
        logger.warning(
            "SetFile not found; set modified time only for %s "
            "(install Xcode command-line tools to set 'Date Created')", path,
        )
        return False

    # SetFile -d expects local time formatted as MM/DD/YYYY HH:MM:SS. The path
    # is resolved to absolute so a name starting with '-' can't read as a flag.
    stamp = dt.astimezone().strftime("%m/%d/%Y %H:%M:%S")
    result = subprocess.run(
        ["SetFile", "-d", stamp, str(path.resolve())],
        capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        logger.warning("SetFile failed for %s: %s", path, result.stderr.strip())
        return False
    return True
