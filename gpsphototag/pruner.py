"""Find and delete RAW files whose same-name JPG/HEIC companion is missing.

Culling workflow: shoot RAW+JPEG, review and delete the rejects' JPGs in a
viewer, then run ``--prune-raw`` to remove the RAW files left behind. The
companion check looks at the filesystem rather than the resolved photo list,
so passing only ``*.raf`` still sees the JPGs sitting next to them.
"""

from __future__ import annotations

from pathlib import Path

from gpsphototag.collectors import NATIVE_EXTS, RAW_EXTS
from gpsphototag.raw_writer import sidecar_path_for


def find_orphan_raws(photos: list[Path]) -> list[Path]:
    """Return the RAW files in ``photos`` with no same-stem native sibling.

    A RAW is kept when a file with the same stem and a native extension
    (.jpg/.jpeg/.heic/...) exists in the same directory; the comparison is
    case-insensitive so ``DSCF0001.RAF`` is protected by ``dscf0001.jpg``.
    Non-RAW entries in ``photos`` are ignored.
    """
    native_stems: dict[Path, set[str]] = {}
    orphans: list[Path] = []
    for photo in photos:
        if photo.suffix.lower() not in RAW_EXTS:
            continue
        directory = photo.parent
        if directory not in native_stems:
            native_stems[directory] = {
                f.stem.lower() for f in directory.iterdir()
                if f.is_file() and f.suffix.lower() in NATIVE_EXTS
            }
        if photo.stem.lower() not in native_stems[directory]:
            orphans.append(photo)
    return orphans


def delete_raw(raw: Path) -> list[Path]:
    """Delete ``raw`` and its XMP sidecar, if present. Returns deleted paths."""
    raw.unlink()
    deleted = [raw]
    sidecar = sidecar_path_for(raw)
    if sidecar.is_file():
        sidecar.unlink()
        deleted.append(sidecar)
    return deleted
