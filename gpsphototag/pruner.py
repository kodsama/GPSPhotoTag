"""Find and remove RAW files whose JPG/HEIC companion is missing.

Culling workflow: shoot RAW+JPEG, review and delete the rejects' JPGs in a
viewer, then run ``--prune-raw`` to clear the RAW files left behind. The
companion check scans the whole tree under the photos' common root, so the
JPGs and RAWs may live in different folders (e.g. RAWs in a ``RAF/`` subfolder,
JPGs alongside) and a same-stem JPEG/HEIC *anywhere* in the tree still protects
its RAW. Orphans are moved to the OS Trash by default (recoverable); pass
``hard=True`` to delete them outright.
"""

from __future__ import annotations

import os
from pathlib import Path

from gpsphototag.collectors import RAW_EXTS
from gpsphototag.raw_writer import sidecar_path_for

# A RAW is kept when a same-stem JPEG or HEIC exists anywhere in the tree.
COMPANION_EXTS: frozenset[str] = frozenset({".jpg", ".jpeg", ".heic", ".heif"})


def _common_root(paths: list[Path]) -> Path:
    """Deepest directory that contains every path in ``paths``."""
    return Path(os.path.commonpath([str(p.parent) for p in paths]))


def find_orphan_raws(photos: list[Path]) -> list[Path]:
    """Return the RAW files in ``photos`` with no same-stem JPEG/HEIC companion.

    The companion search scans the whole tree under the common root of
    ``photos`` (case-insensitively), so ``RAF/DSCF0001.RAF`` is protected by
    ``DSCF0001.JPG`` sitting in a parent or sibling folder. Non-RAW entries are
    ignored.
    """
    raws = [p for p in photos if p.suffix.lower() in RAW_EXTS]
    if not raws:
        return []
    root = _common_root(photos)
    companion_stems = {
        f.stem.lower()
        for f in root.rglob("*")
        if f.is_file() and f.suffix.lower() in COMPANION_EXTS
    }
    return [raw for raw in raws if raw.stem.lower() not in companion_stems]


def _discard(path: Path, *, hard: bool) -> None:
    """Move ``path`` to the OS Trash, or delete it outright when ``hard``.

    Trashing goes through ``send2trash``, which picks the correct mechanism for
    macOS, Linux (XDG), or Windows.
    """
    if hard:
        path.unlink()
        return
    from send2trash import send2trash
    send2trash(os.fspath(path))


def delete_raw(raw: Path, *, hard: bool = False) -> list[Path]:
    """Trash (default) or delete ``raw`` and its XMP sidecar. Returns the paths."""
    targets = [raw]
    sidecar = sidecar_path_for(raw)
    if sidecar.is_file():
        targets.append(sidecar)
    for path in targets:
        _discard(path, hard=hard)
    return targets
