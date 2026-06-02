"""Resolve user-supplied --photo / --gps / --maps-history values into paths.

Each value can be a file, directory, or glob pattern. Directories are scanned
recursively. The result is a flat, de-duplicated, sorted list of absolute
paths filtered by the requested extensions.
"""

from __future__ import annotations

import glob
import logging
from collections.abc import Iterable
from pathlib import Path

logger = logging.getLogger(__name__)

RAW_EXTS: frozenset[str] = frozenset({
    ".raf",  # Fujifilm
    ".nef", ".nrw",  # Nikon
    ".cr2", ".cr3", ".crw",  # Canon
    ".arw", ".sr2", ".srf",  # Sony
    ".dng",  # Adobe / many vendors
    ".rw2",  # Panasonic
    ".orf",  # Olympus
    ".pef", ".ptx",  # Pentax
    ".raw",  # generic
    ".rwl",  # Leica
    ".srw",  # Samsung
    ".x3f",  # Sigma
    ".iiq",  # Phase One
    ".3fr",  # Hasselblad
    ".erf",  # Epson
})
NATIVE_EXTS: frozenset[str] = frozenset({".jpg", ".jpeg", ".heic", ".heif", ".png"})
PHOTO_EXTS: frozenset[str] = NATIVE_EXTS | RAW_EXTS
GPX_EXTS: frozenset[str] = frozenset({".gpx"})
MAPS_EXTS: frozenset[str] = frozenset({".json", ".kml"})


def _case_insensitive(pattern: str) -> str:
    """Rewrite a glob pattern so it matches case-insensitively.

    Each ASCII letter becomes a ``[aA]`` class, so ``*.raf`` matches ``.RAF``
    and ``*.JPG`` matches ``.jpg``. Letters already inside a ``[...]`` class are
    left untouched (the user controls those). This widens directory components
    too, which matches the de-facto behaviour on case-insensitive filesystems.
    """
    out: list[str] = []
    in_class = False
    for ch in pattern:
        if ch == "[":
            in_class = True
            out.append(ch)
        elif ch == "]":
            in_class = False
            out.append(ch)
        elif ch.isascii() and ch.isalpha() and not in_class:
            out.append(f"[{ch.lower()}{ch.upper()}]")
        else:
            out.append(ch)
    return "".join(out)


def _walk(directory: Path, extensions: Iterable[str]) -> list[Path]:
    """Recursively yield files under ``directory`` matching ``extensions``."""
    exts = {e.lower() for e in extensions}
    return [p for p in directory.rglob("*") if p.is_file() and p.suffix.lower() in exts]


def _expand_one(value: str, extensions: Iterable[str]) -> list[Path]:
    """Resolve a single user value to a list of paths.

    Order: existing file → existing directory (recursive) → glob pattern.
    Hits are filtered by ``extensions`` (case-insensitive).
    """
    exts = {e.lower() for e in extensions}
    p = Path(value).expanduser()

    if p.is_file():
        if p.suffix.lower() in exts:
            return [p.resolve()]
        logger.debug("Skipping %s — extension not in %s", p, sorted(exts))
        return []

    if p.is_dir():
        return [m.resolve() for m in _walk(p, exts)]

    matches = [Path(m) for m in glob.glob(_case_insensitive(value), recursive=True)]
    out: list[Path] = []
    for m in matches:
        if m.is_file() and m.suffix.lower() in exts:
            out.append(m.resolve())
        elif m.is_dir():
            out.extend(x.resolve() for x in _walk(m, exts))
    if not matches:
        logger.warning("No matches for %r", value)
    return out


def collect_paths(values: list[list[str]] | None, extensions: Iterable[str]) -> list[Path]:
    """Flatten argparse `action='append', nargs='+'` output into a path list.

    Removes duplicates, sorts deterministically. Returns ``[]`` for ``None``.
    """
    if not values:
        return []
    seen: set[Path] = set()
    result: list[Path] = []
    for sub in values:
        for value in sub:
            for p in _expand_one(value, extensions):
                if p not in seen:
                    seen.add(p)
                    result.append(p)
    result.sort()
    return result
