"""Read photo timestamps and write GPS EXIF.

JPEG is written losslessly via ``piexif`` (no pixel re-encoding). HEIC and
PNG go through Pillow's ``save(..., exif=...)``, which re-encodes the pixel
data — see the README caveat. RAW formats dispatch to ``raw_writer`` for
sidecar or exiftool-based writes (RAW pixel data is never touched by
GPSPhotoTag). Reads for JPEG/HEIC/PNG use Pillow; RAW reads use ``exifread``.
"""

from __future__ import annotations

import logging
import shutil
from datetime import datetime, timedelta, timezone, tzinfo
from pathlib import Path

import piexif
from PIL import ExifTags, Image

from gpsphototag import raw_writer
from gpsphototag.collectors import RAW_EXTS

try:
    import pillow_heif  # type: ignore
    pillow_heif.register_heif_opener()
except Exception:  # pragma: no cover - environment without pillow_heif
    pillow_heif = None  # type: ignore

logger = logging.getLogger(__name__)

JPEG_EXTS = {".jpg", ".jpeg"}
HEIC_EXTS = {".heic", ".heif"}
PNG_EXTS = {".png"}

_TAG_DATETIME_ORIGINAL = next(k for k, v in ExifTags.TAGS.items() if v == "DateTimeOriginal")
_TAG_OFFSET_ORIGINAL = next((k for k, v in ExifTags.TAGS.items() if v == "OffsetTimeOriginal"), 36881)
_TAG_GPSINFO = next(k for k, v in ExifTags.TAGS.items() if v == "GPSInfo")


def _parse_offset(s: str) -> tzinfo | None:
    """Parse an EXIF offset like ``+02:00`` into a tzinfo."""
    s = s.strip()
    if not s or s in ("Z", "+00:00", "-00:00"):
        return timezone.utc
    try:
        sign = 1 if s[0] == "+" else -1
        hh, mm = s[1:].split(":")
        return timezone(sign * timedelta(hours=int(hh), minutes=int(mm)))
    except (ValueError, IndexError):
        return None


def read_timestamp(path: Path, fallback_tz: tzinfo) -> datetime | None:
    """Return ``DateTimeOriginal`` as a tz-aware datetime, or None.

    Applies ``OffsetTimeOriginal`` when present; otherwise ``fallback_tz``.
    RAW formats route through ``exifread``; everything else through Pillow.
    """
    if path.suffix.lower() in RAW_EXTS:
        ts, _ = raw_writer.read_raw_metadata(path, fallback_tz=fallback_tz)
        return ts
    try:
        with Image.open(path) as img:
            exif = img.getexif()
            # DateTimeOriginal lives in the EXIF sub-IFD (0x8769).
            ifd = exif.get_ifd(0x8769)
            dt_raw = ifd.get(_TAG_DATETIME_ORIGINAL) or exif.get(_TAG_DATETIME_ORIGINAL)
            if not dt_raw:
                return None
            offset_raw = ifd.get(_TAG_OFFSET_ORIGINAL) or exif.get(_TAG_OFFSET_ORIGINAL)
    except Exception as e:
        logger.debug("Could not read EXIF for %s: %s", path, e)
        return None

    try:
        dt = datetime.strptime(str(dt_raw).strip(), "%Y:%m:%d %H:%M:%S")
    except ValueError:
        logger.debug("Unparseable DateTimeOriginal %r for %s", dt_raw, path)
        return None

    tz = _parse_offset(str(offset_raw)) if offset_raw else None
    return dt.replace(tzinfo=tz or fallback_tz)


def has_gps(path: Path) -> bool:
    """True if the photo already carries a usable GPS latitude tag.

    For RAW files we look both inside the file (via ``exifread``) and at the
    sibling XMP sidecar — either counts as 'already tagged'.
    """
    suffix = path.suffix.lower()
    if suffix in RAW_EXTS:
        _, gps_in_raw = raw_writer.read_raw_metadata(path, fallback_tz=timezone.utc)
        if gps_in_raw:
            return True
        return raw_writer.sidecar_path_for(path).exists()
    try:
        with Image.open(path) as img:
            exif = img.getexif()
            gps = exif.get_ifd(_TAG_GPSINFO)
            return bool(gps) and 2 in gps  # tag 2 = GPSLatitude
    except Exception as e:
        logger.debug("Could not inspect GPS for %s: %s", path, e)
        return False


def _to_dms(value: float) -> tuple[tuple[int, int], tuple[int, int], tuple[int, int]]:
    """Convert decimal degrees → ((deg,1),(min,1),(sec*10000,10000)) rationals."""
    v = abs(value)
    deg = int(v)
    minutes_full = (v - deg) * 60.0
    minutes = int(minutes_full)
    seconds = (minutes_full - minutes) * 60.0
    sec_num = int(round(seconds * 10000))
    return ((deg, 1), (minutes, 1), (sec_num, 10000))


def _build_gps_ifd(lat: float, lon: float) -> dict:
    """piexif GPS IFD dict for ``lat``/``lon`` in decimal degrees, WGS-84."""
    return {
        piexif.GPSIFD.GPSVersionID: (2, 0, 0, 0),
        piexif.GPSIFD.GPSLatitudeRef: b"N" if lat >= 0 else b"S",
        piexif.GPSIFD.GPSLatitude: _to_dms(lat),
        piexif.GPSIFD.GPSLongitudeRef: b"E" if lon >= 0 else b"W",
        piexif.GPSIFD.GPSLongitude: _to_dms(lon),
        piexif.GPSIFD.GPSMapDatum: b"WGS-84",
    }


def _empty_exif() -> dict:
    """A blank piexif dict with all IFDs present."""
    return {"0th": {}, "Exif": {}, "GPS": {}, "1st": {}, "thumbnail": None}


def _load_exif(src: Path) -> dict:
    """Load EXIF from ``src`` as a piexif dict, or a blank one on failure."""
    try:
        return piexif.load(str(src))
    except (piexif.InvalidImageDataError, ValueError, FileNotFoundError):
        return _empty_exif()


def _apply_datetime(exif_dict: dict, dt: datetime) -> None:
    """Set DateTimeOriginal/Digitized/DateTime (+ offset) in ``exif_dict``."""
    stamp = dt.strftime("%Y:%m:%d %H:%M:%S").encode("ascii")
    exif_dict["Exif"][piexif.ExifIFD.DateTimeOriginal] = stamp
    exif_dict["Exif"][piexif.ExifIFD.DateTimeDigitized] = stamp
    exif_dict["0th"][piexif.ImageIFD.DateTime] = stamp
    offset = dt.utcoffset()
    if offset is not None:
        total = int(offset.total_seconds() // 60)
        sign = "+" if total >= 0 else "-"
        total = abs(total)
        off = f"{sign}{total // 60:02d}:{total % 60:02d}".encode("ascii")
        exif_dict["Exif"][piexif.ExifIFD.OffsetTimeOriginal] = off


def _apply_native(src: Path, dst: Path, gps, dt, *, fmt: str | None) -> None:
    """Write GPS and/or datetime into a JPEG (lossless) or via Pillow re-encode.

    ``fmt`` is None for JPEG (use piexif.insert), else a Pillow format string.
    """
    exif_dict = _load_exif(src)
    if gps is not None:
        exif_dict["GPS"] = _build_gps_ifd(*gps)
    if dt is not None:
        _apply_datetime(exif_dict, dt)

    if fmt is None:  # JPEG: lossless insert
        exif_bytes = piexif.dump(exif_dict)
        if src.resolve() != dst.resolve():
            shutil.copyfile(src, dst)
        piexif.insert(exif_bytes, str(dst))
        return

    exif_dict.pop("thumbnail", None)  # Pillow chokes on some thumbnails
    exif_bytes = piexif.dump(exif_dict)
    with Image.open(src) as img:
        img.load()
        save_kwargs = {"format": fmt, "exif": exif_bytes}
        if fmt == "HEIF":
            save_kwargs["quality"] = 90
        img.save(dst, **save_kwargs)


def apply_exif(src: Path, dst: Path, *, gps=None, dt=None, raw_mode: str = "auto") -> None:
    """Write GPS coordinates and/or a datetime into ``dst`` in one pass.

    ``gps`` is ``(lat, lon)`` or None; ``dt`` is a tz-aware datetime or None.
    Doing both at once avoids a second load clobbering the first write. For
    RAW files, ``raw_mode="auto"`` (default) embeds via exiftool when it's
    available, else writes an XMP sidecar; a datetime can only be embedded, so
    a sidecar-resolved RAW with ``dt`` raises ``ValueError``.
    """
    suffix = src.suffix.lower()
    dst.parent.mkdir(parents=True, exist_ok=True)

    if suffix in JPEG_EXTS:
        _apply_native(src, dst, gps, dt, fmt=None)
    elif suffix in HEIC_EXTS:
        if pillow_heif is None:  # pragma: no cover - environment without pillow_heif
            raise RuntimeError("pillow_heif required for HEIC writes")
        _apply_native(src, dst, gps, dt, fmt="HEIF")
    elif suffix in PNG_EXTS:
        _apply_native(src, dst, gps, dt, fmt="PNG")
    elif suffix in RAW_EXTS:
        mode = raw_writer.resolve_raw_mode(raw_mode)
        if dt is not None and mode != "embed":
            raise ValueError("RAW datetime writes require --raw-mode embed (needs exiftool)")
        if mode == "embed":
            raw_writer.write_embedded(src, dst, gps=gps, dt=dt)
        elif gps is not None:
            raw_writer.write_sidecar(src, dst, *gps)
    else:
        raise ValueError(f"Unsupported photo extension: {suffix}")


def write_gps(src: Path, dst: Path, lat: float, lon: float, *, raw_mode: str = "auto") -> None:
    """Write only GPS into ``dst`` (thin wrapper over :func:`apply_exif`)."""
    apply_exif(src, dst, gps=(lat, lon), dt=None, raw_mode=raw_mode)
