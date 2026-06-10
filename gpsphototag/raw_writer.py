"""RAW file support: read EXIF via ``exifread``, write via sidecar or exiftool.

GPSPhotoTag never modifies a RAW pixel-data file directly. Two write modes:

* **sidecar** (default) — writes ``photo.raf.xmp`` next to the RAW. Pure
  Python, no external binary, RAW left untouched. Lightroom, darktable,
  digiKam, and most cataloguers read these sidecars.
* **embed** — shells out to the ``exiftool`` binary (must be on PATH) which
  writes GPS tags inside the RAW container. Use when downstream tools
  don't read XMP sidecars.

Reading timestamps is always via ``exifread`` — pure-Python and handles
most RAW formats (RAF/NEF/CR2/CR3/ARW/DNG/RW2/ORF/PEF…).
"""

from __future__ import annotations

import json
import logging
import re
import shutil
import subprocess
from datetime import datetime, tzinfo
from pathlib import Path
from shutil import which

import exifread

from gpsphototag.dates import parse_exif_datetime

logger = logging.getLogger(__name__)


def exiftool_available() -> bool:
    """True if the ``exiftool`` binary is discoverable on PATH."""
    return which("exiftool") is not None


def resolve_raw_mode(mode: str) -> str:
    """Resolve the RAW write mode to a concrete ``"embed"`` or ``"sidecar"``.

    ``"auto"`` (the default) prefers embedding GPS directly into the RAW via
    ``exiftool`` when it's available, falling back to an XMP sidecar otherwise.
    ``"embed"`` and ``"sidecar"`` are returned unchanged.
    """
    if mode == "auto":
        return "embed" if exiftool_available() else "sidecar"
    return mode


def _exiftool_json(path: Path, args: list[str]) -> dict | None:
    """Run ``exiftool -json <args> <path>`` and return the first record.

    The path is resolved to absolute so a filename starting with ``-`` can
    never be misread as an exiftool option. Returns None when exiftool is
    unavailable, exits non-zero, or emits unparseable output.
    """
    if not exiftool_available():
        return None
    cmd = ["exiftool", "-json", *args, str(path.resolve())]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    except OSError as e:  # pragma: no cover - exiftool vanished mid-run
        logger.debug("exiftool read failed for %s: %s", path, e)
        return None
    if result.returncode != 0 or not result.stdout.strip():
        return None
    try:
        return json.loads(result.stdout)[0]
    except (json.JSONDecodeError, IndexError):
        return None


def _read_with_exiftool(path: Path, fallback_tz: tzinfo) -> tuple[datetime | None, bool]:
    """Read ``(timestamp, has_gps)`` via the ``exiftool`` binary.

    Used as a fallback for RAW containers ``exifread`` cannot parse (Fujifilm
    ``.RAF``, Canon ``.CR3``, …). Returns ``(None, False)`` when exiftool is
    absent or yields nothing usable.
    """
    data = _exiftool_json(path, ["-DateTimeOriginal", "-CreateDate",
                                 "-OffsetTimeOriginal", "-GPSLatitude"])
    if data is None:
        return None, False
    has_gps = "GPSLatitude" in data
    dt_raw = data.get("DateTimeOriginal") or data.get("CreateDate")
    if not dt_raw:
        return None, has_gps
    return parse_exif_datetime(str(dt_raw), data.get("OffsetTimeOriginal"), fallback_tz), has_gps


def read_raw_metadata(path: Path, fallback_tz: tzinfo) -> tuple[datetime | None, bool]:
    """Return ``(timestamp, has_gps)`` for a RAW file.

    Tries ``exifread`` first (fast, pure-Python, covers TIFF-based RAW). When
    it can't read a timestamp — e.g. Fujifilm ``.RAF`` or Canon ``.CR3``,
    whose containers exifread doesn't recognize — falls back to ``exiftool``.
    """
    try:
        with path.open("rb") as fh:
            tags = exifread.process_file(fh, details=False, stop_tag="GPS GPSLatitude")
    except Exception as e:
        logger.debug("exifread failed for %s: %s", path, e)
        tags = {}

    dt_tag = tags.get("EXIF DateTimeOriginal") or tags.get("Image DateTime")
    offset_tag = tags.get("EXIF OffsetTimeOriginal")
    has_gps = "GPS GPSLatitude" in tags

    if dt_tag is not None:
        dt = parse_exif_datetime(str(dt_tag), str(offset_tag) if offset_tag else None, fallback_tz)
        if dt is not None:
            return dt, has_gps
        logger.debug("Unparseable RAW DateTimeOriginal %r in %s", dt_tag, path)

    # exifread gave us no timestamp — fall back to exiftool, which understands
    # far more RAW containers.
    if exiftool_available():
        dt, gps_xt = _read_with_exiftool(path, fallback_tz)
        return dt, (has_gps or gps_xt)

    logger.warning("Could not read EXIF from %s; install exiftool for full RAW "
                   "support (e.g. Fujifilm .RAF, Canon .CR3).", path.name)
    return None, has_gps


def sidecar_path_for(raw_path: Path) -> Path:
    """Return the conventional XMP sidecar path next to ``raw_path``."""
    return raw_path.with_suffix(raw_path.suffix + ".xmp")


def _from_xmp_coord(value: str) -> float | None:
    """Parse an XMP ``DD,MM.MMMMM[N|S|E|W]`` coordinate back to decimal degrees."""
    s = value.strip()
    if not s or "," not in s:
        return None
    hemi = s[-1].upper()
    if hemi not in ("N", "S", "E", "W"):
        return None
    try:
        deg_str, min_str = s[:-1].split(",")
        decimal = int(deg_str) + float(min_str) / 60.0
    except (ValueError, IndexError):
        return None
    return -decimal if hemi in ("S", "W") else decimal


def _read_sidecar_gps(raw_path: Path) -> tuple[float, float] | None:
    """Read ``(lat, lon)`` from the XMP sidecar next to ``raw_path``, or None."""
    sidecar = sidecar_path_for(raw_path)
    if not sidecar.exists():
        return None
    text = sidecar.read_text(encoding="utf-8")
    lat_m = re.search(r"<exif:GPSLatitude>(.*?)</exif:GPSLatitude>", text)
    lon_m = re.search(r"<exif:GPSLongitude>(.*?)</exif:GPSLongitude>", text)
    if not lat_m or not lon_m:
        return None
    lat = _from_xmp_coord(lat_m.group(1))
    lon = _from_xmp_coord(lon_m.group(1))
    if lat is None or lon is None:
        return None
    return lat, lon


def _read_embedded_gps(raw_path: Path) -> tuple[float, float] | None:
    """Read embedded ``(lat, lon)`` via exiftool numeric output, or None."""
    data = _exiftool_json(raw_path, ["-n", "-GPSLatitude", "-GPSLongitude"])
    if data is None:
        return None
    try:
        return float(data["GPSLatitude"]), float(data["GPSLongitude"])
    except (KeyError, TypeError, ValueError):
        return None


def read_raw_gps(raw_path: Path) -> tuple[float, float] | None:
    """Return ``(lat, lon)`` for a RAW file, preferring the XMP sidecar.

    Mirrors :func:`gpsphototag.exif.has_gps`'s RAW handling: an XMP sidecar
    written by GPSPhotoTag takes precedence; otherwise we ask ``exiftool`` for
    coordinates embedded in the RAW container. Returns None when neither has GPS.
    """
    return _read_sidecar_gps(raw_path) or _read_embedded_gps(raw_path)


def _to_xmp_coord(value: float, *, is_latitude: bool) -> str:
    """Format a decimal degree as XMP's ``DD,MM.MMMMM[N|S]`` string."""
    hemi = ("N" if value >= 0 else "S") if is_latitude else ("E" if value >= 0 else "W")
    v = abs(value)
    deg = int(v)
    minutes = (v - deg) * 60.0
    return f"{deg},{minutes:.5f}{hemi}"


def build_xmp(lat: float, lon: float) -> str:
    """Return a minimal, well-formed XMP document carrying GPS coordinates."""
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="GPSPhotoTag">\n'
        '  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"\n'
        '           xmlns:exif="http://ns.adobe.com/exif/1.0/">\n'
        '    <rdf:Description rdf:about="">\n'
        f'      <exif:GPSLatitude>{_to_xmp_coord(lat, is_latitude=True)}</exif:GPSLatitude>\n'
        f'      <exif:GPSLongitude>{_to_xmp_coord(lon, is_latitude=False)}</exif:GPSLongitude>\n'
        '      <exif:GPSMapDatum>WGS-84</exif:GPSMapDatum>\n'
        '    </rdf:Description>\n'
        '  </rdf:RDF>\n'
        '</x:xmpmeta>\n'
    )


def write_sidecar(raw_src: Path, raw_dst: Path, lat: float, lon: float) -> Path:
    """Write an XMP sidecar for ``raw_dst``. Returns the sidecar path.

    If ``raw_src`` and ``raw_dst`` differ, the RAW is also copied so that
    ``--out`` produces a self-contained output directory.
    """
    raw_dst.parent.mkdir(parents=True, exist_ok=True)
    if raw_src.resolve() != raw_dst.resolve() and not raw_dst.exists():
        shutil.copy2(raw_src, raw_dst)
    sidecar = sidecar_path_for(raw_dst)
    sidecar.write_text(build_xmp(lat, lon), encoding="utf-8")
    return sidecar


def write_embedded(raw_src: Path, raw_dst: Path, *, gps=None, dt=None) -> None:
    """Run ``exiftool`` to embed GPS and/or a datetime into the RAW container.

    ``gps`` is ``(lat, lon)`` or None; ``dt`` is a tz-aware datetime or None.
    Raises ``RuntimeError`` if exiftool is missing or exits non-zero, and
    ``ValueError`` if neither field is provided.
    """
    if gps is None and dt is None:
        raise ValueError("write_embedded requires gps and/or dt")
    if not exiftool_available():
        raise RuntimeError("exiftool not found on PATH (required for --raw-mode embed)")

    if raw_src.resolve() != raw_dst.resolve():
        raw_dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(raw_src, raw_dst)

    cmd = ["exiftool", "-overwrite_original"]
    if gps is not None:
        lat, lon = gps
        cmd += [
            f"-GPSLatitude={abs(lat)}", f"-GPSLatitudeRef={'N' if lat >= 0 else 'S'}",
            f"-GPSLongitude={abs(lon)}", f"-GPSLongitudeRef={'E' if lon >= 0 else 'W'}",
            "-GPSMapDatum=WGS-84",
        ]
    if dt is not None:
        stamp = dt.strftime("%Y:%m:%d %H:%M:%S")
        cmd += [f"-DateTimeOriginal={stamp}", f"-CreateDate={stamp}"]
    # Absolute path so a filename starting with '-' can't read as an option.
    cmd.append(str(raw_dst.resolve()))

    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"exiftool failed: {result.stderr.strip() or result.stdout.strip()}")
