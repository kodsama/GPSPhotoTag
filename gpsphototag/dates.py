"""Read and set filesystem timestamps for ``--fix-dates``.

Two directions, driven by the CLI:

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
from datetime import datetime
from pathlib import Path
from shutil import which

logger = logging.getLogger(__name__)


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

    # SetFile -d expects local time formatted as MM/DD/YYYY HH:MM:SS.
    stamp = dt.astimezone().strftime("%m/%d/%Y %H:%M:%S")
    result = subprocess.run(
        ["SetFile", "-d", stamp, str(path)],
        capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        logger.warning("SetFile failed for %s: %s", path, result.stderr.strip())
        return False
    return True
