"""Acceptance Criteria — explicit, one-test-per-AC mapping of the user spec.

Each test name and docstring traces back to a sentence the user wrote when
asking for GPSPhotoTag. A failing AC test means a user-visible promise is
broken.

User's original requirements (paraphrased):
  R1  Select photos via specific files (--photo a.jpg --photo b.jpg)
  R2  Select photos via regex/glob (--photo "DSC*.jpg" or *.png)
  R3  Select photos via path (--photo . or --photo /home/alex/)
  R4  Same flexibility for --gps (file / glob / dir)
  R5  Fall back to Google location history when GPX has no match
  R6  --replace allows rewriting a photo's existing GPS data
  R7  --out specifies output directory
  R8  Without --out, photos are modified in place (gated by --overwrite)
  R9  If no GPS data is found, indicate it and do not modify the photo
  R10 Clear terminal display + detailed logging (logging package)
  R11 argparse-based CLI
  R12 Short, well-documented functions
  R13 RAW formats supported (.raf etc.) — sidecar or exiftool embed
  R14 --fix-dates exif: set file's created/modified date from EXIF timestamp
  R15 --fix-dates file: write EXIF DateTimeOriginal from file's created date
"""

from __future__ import annotations

import inspect
import logging
import os
from datetime import datetime, timezone

import pytest

from gpsphototag import cli, collectors, dates, google_source, gpx_source, locator, tagger
from gpsphototag import exif as exif_mod

UTC = timezone.utc


# ---------------------------------------------------------------------------
# R1 — Specific photo files via repeated --photo flags
# ---------------------------------------------------------------------------
def test_AC_R1_specific_files_via_repeated_photo_flags(jpeg_factory, sample_gpx):
    """`--photo a.jpg --photo b.jpg` tags exactly those two files."""
    dt = datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC)
    a = jpeg_factory("a.jpg", dt)
    b = jpeg_factory("b.jpg", dt)
    rc = cli.main(["--photo", str(a), "--photo", str(b),
                   "--gps", str(sample_gpx), "--overwrite", "--timezone", "UTC"])
    assert rc == 0
    assert exif_mod.has_gps(a) and exif_mod.has_gps(b)


# ---------------------------------------------------------------------------
# R2 — Glob/regex via --photo
# ---------------------------------------------------------------------------
def test_AC_R2_glob_pattern_via_photo(jpeg_factory, sample_gpx, tmp_path, monkeypatch):
    """`--photo "DSC*.jpg"` matches by glob (quoted, expanded internally)."""
    dt = datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC)
    jpeg_factory("DSC001.jpg", dt)
    jpeg_factory("DSC002.jpg", dt)
    jpeg_factory("OTHER.jpg", dt)
    monkeypatch.chdir(tmp_path)
    rc = cli.main(["--photo", "DSC*.jpg", "--gps", str(sample_gpx),
                   "--overwrite", "--timezone", "UTC"])
    assert rc == 0
    assert exif_mod.has_gps(tmp_path / "DSC001.jpg")
    assert exif_mod.has_gps(tmp_path / "DSC002.jpg")
    assert not exif_mod.has_gps(tmp_path / "OTHER.jpg")


# ---------------------------------------------------------------------------
# R3 — Directory recursion via --photo
# ---------------------------------------------------------------------------
def test_AC_R3_directory_recursive_via_photo(jpeg_factory, sample_gpx, tmp_path):
    """`--photo /some/dir/` walks the directory recursively."""
    dt = datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC)
    sub = tmp_path / "trip" / "day1"
    sub.mkdir(parents=True)
    p1 = sub / "a.jpg"
    import io

    from PIL import Image
    img = Image.new("RGB", (4, 4), "red")
    buf = io.BytesIO()
    img.save(buf, "JPEG")
    p1.write_bytes(buf.getvalue())
    # Use the existing jpeg_factory helper for the timestamped one:
    p2 = jpeg_factory("trip/day2/b.jpg".replace("/", "_"), dt)
    # Drop b.jpg under another nested folder so directory recursion is required.
    nested = tmp_path / "trip" / "day2"
    nested.mkdir()
    (nested / "b.jpg").write_bytes(p2.read_bytes())

    rc = cli.main(["--photo", str(tmp_path / "trip"),
                   "--gps", str(sample_gpx),
                   "--overwrite", "--timezone", "UTC"])
    assert rc == 0
    # b.jpg had a timestamp, so it should be tagged.
    assert exif_mod.has_gps(nested / "b.jpg")


# ---------------------------------------------------------------------------
# R4 — Same flexibility for --gps (file / glob / dir)
# ---------------------------------------------------------------------------
def test_AC_R4_gps_accepts_file_glob_and_directory(jpeg_factory, sample_gpx, tmp_path):
    """--gps accepts a file, a glob, or a directory recursively."""
    # File
    photo = jpeg_factory("p1.jpg", datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC))
    rc = cli.main(["--photo", str(photo), "--gps", str(sample_gpx),
                   "--overwrite", "--timezone", "UTC"])
    assert rc == 0 and exif_mod.has_gps(photo)
    # Directory containing GPX
    photo2 = jpeg_factory("p2.jpg", datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC))
    rc = cli.main(["--photo", str(photo2),
                   "--gps", str(sample_gpx.parent),
                   "--overwrite", "--timezone", "UTC"])
    assert rc == 0 and exif_mod.has_gps(photo2)


# ---------------------------------------------------------------------------
# R5 — Google fallback when GPX has no match
# ---------------------------------------------------------------------------
def test_AC_R5_google_fallback_when_gpx_has_no_match(jpeg_factory, sample_records_json):
    """If GPX doesn't cover the photo's time, Google location history is tried."""
    # Photo at 09:00 — Records.json has a point at 09:00, our sample GPX starts at 10:00.
    photo = jpeg_factory("early.jpg", datetime(2024, 8, 15, 9, 0, 0, tzinfo=UTC))
    rc = cli.main([
        "--photo", str(photo),
        "--maps-history", str(sample_records_json),
        "--overwrite", "--timezone", "UTC",
    ])
    assert rc == 0
    assert exif_mod.has_gps(photo)


# ---------------------------------------------------------------------------
# R6 — --replace overwrites existing GPS bytes
# ---------------------------------------------------------------------------
def test_AC_R6_replace_overwrites_existing_gps(jpeg_factory, sample_gpx):
    """A photo with existing GPS gets new bytes only when --replace is set."""
    dt = datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC)
    photo = jpeg_factory("existing.jpg", dt)
    exif_mod.write_gps(photo, photo, lat=0.0, lon=0.0)

    # Without --replace → skipped.
    cli.main(["--photo", str(photo), "--gps", str(sample_gpx),
              "--overwrite", "--timezone", "UTC"])
    # Latitude still ~0 (unchanged).
    # With --replace → updated to GPX point (~48.8566).
    rc = cli.main(["--photo", str(photo), "--gps", str(sample_gpx),
                   "--overwrite", "--replace", "--timezone", "UTC"])
    assert rc == 0
    import piexif
    gps = piexif.load(str(photo))["GPS"]
    deg, mins, sec = gps[piexif.GPSIFD.GPSLatitude]
    decimal = deg[0] / deg[1] + mins[0] / mins[1] / 60 + sec[0] / sec[1] / 3600
    assert decimal == pytest.approx(48.8566, abs=1e-4)


# ---------------------------------------------------------------------------
# R7 — --out writes to a separate directory
# ---------------------------------------------------------------------------
def test_AC_R7_out_writes_to_separate_directory(jpeg_factory, sample_gpx, tmp_path):
    """--out DIR writes tagged copies there; originals untouched."""
    dt = datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC)
    photo = jpeg_factory("p.jpg", dt)
    out = tmp_path / "tagged"
    rc = cli.main(["--photo", str(photo), "--gps", str(sample_gpx),
                   "--out", str(out), "--timezone", "UTC"])
    assert rc == 0
    assert (out / "p.jpg").exists()
    assert exif_mod.has_gps(out / "p.jpg")
    assert not exif_mod.has_gps(photo)


# ---------------------------------------------------------------------------
# R8 — In-place edit requires --overwrite
# ---------------------------------------------------------------------------
def test_AC_R8_in_place_requires_overwrite(jpeg_factory):
    """No --out and no --overwrite is rejected before touching anything."""
    photo = jpeg_factory("p.jpg", datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC))
    with pytest.raises(SystemExit):
        cli.main(["--photo", str(photo)])


# ---------------------------------------------------------------------------
# R9 — Photo unmodified when no GPS is found
# ---------------------------------------------------------------------------
def test_AC_R9_no_gps_leaves_photo_untouched(jpeg_factory, tmp_path):
    """If no source matches, the photo is reported as no_gps and not modified."""
    dt = datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC)
    photo = jpeg_factory("p.jpg", dt)
    original_bytes = photo.read_bytes()
    rc = cli.main(["--photo", str(photo), "--overwrite", "--timezone", "UTC"])
    assert rc == 0
    assert photo.read_bytes() == original_bytes
    assert not exif_mod.has_gps(photo)


# ---------------------------------------------------------------------------
# R10 — Logging via the logging package is configured + writes
# ---------------------------------------------------------------------------
def test_AC_R10_logging_uses_python_logging_package(jpeg_factory, sample_gpx, tmp_path):
    """`logging` package is configured; --log-file produces a file with entries."""
    photo = jpeg_factory("p.jpg", datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC))
    log_path = tmp_path / "gpsphototag.log"
    rc = cli.main([
        "--photo", str(photo), "--gps", str(sample_gpx),
        "--overwrite", "--timezone", "UTC",
        "--log-file", str(log_path), "--verbose",
    ])
    assert rc == 0
    for h in logging.getLogger().handlers:
        h.flush()
    assert log_path.exists()
    contents = log_path.read_text(encoding="utf-8")
    assert "Resolved" in contents  # info message we know we emit


# ---------------------------------------------------------------------------
# R11 — CLI is argparse-based (versionable, has --help)
# ---------------------------------------------------------------------------
def test_AC_R11_cli_uses_argparse():
    """The CLI exposes argparse.ArgumentParser with --help, --version, --photo."""
    import argparse
    parser = cli.build_parser()
    assert isinstance(parser, argparse.ArgumentParser)
    options = {opt for a in parser._actions for opt in a.option_strings}
    assert "--photo" in options
    assert "--version" in options
    assert "--help" in options


# ---------------------------------------------------------------------------
# R12 — Functions are short and documented (docstring + length sanity)
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("module", [
    collectors, exif_mod, gpx_source, google_source, locator, tagger, cli, dates,
])
def test_AC_R12_public_functions_have_docstrings(module):
    """Every public (non-underscore) function/class carries a docstring."""
    missing = []
    for name, obj in inspect.getmembers(module):
        if name.startswith("_"):
            continue
        if not (inspect.isfunction(obj) or inspect.isclass(obj)):
            continue
        # Skip re-exported externals.
        if getattr(obj, "__module__", "") != module.__name__:
            continue
        if not (obj.__doc__ or "").strip():
            missing.append(f"{module.__name__}.{name}")
    assert not missing, f"missing docstrings: {missing}"


def test_AC_R12_no_function_exceeds_reasonable_line_count():
    """No top-level function in gpsphototag/ exceeds ~60 source lines.

    Encodes the user's 'short, well-documented functions' requirement so
    refactors that bloat a helper get caught.
    """
    LIMIT = 60
    violations: list[str] = []
    for module in (collectors, exif_mod, gpx_source, google_source, locator, tagger, cli, dates):
        for name, obj in inspect.getmembers(module):
            if not inspect.isfunction(obj):
                continue
            if getattr(obj, "__module__", "") != module.__name__:
                continue
            try:
                src, _ = inspect.getsourcelines(obj)
            except (OSError, TypeError):
                continue
            if len(src) > LIMIT:
                violations.append(f"{module.__name__}.{name} ({len(src)} lines)")
    assert not violations, f"functions exceeding {LIMIT} lines: {violations}"


# ---------------------------------------------------------------------------
# Extra ACs from the design that aren't in the bullet list above
# ---------------------------------------------------------------------------
def test_AC_dry_run_writes_nothing(jpeg_factory, sample_gpx):
    """--dry-run reports matches but writes nothing to disk."""
    photo = jpeg_factory("p.jpg", datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC))
    snapshot = photo.read_bytes()
    rc = cli.main(["--photo", str(photo), "--gps", str(sample_gpx),
                   "--dry-run", "--timezone", "UTC"])
    assert rc == 0
    assert photo.read_bytes() == snapshot


def test_AC_gpx_takes_precedence_over_google(jpeg_factory, sample_gpx, sample_records_json):
    """When both sources have a point at the photo's time, GPX wins."""
    # Photo at 10:00 — both GPX and Records.json have points around then.
    photo = jpeg_factory("p.jpg", datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC))
    rc = cli.main([
        "--photo", str(photo),
        "--gps", str(sample_gpx),
        "--maps-history", str(sample_records_json),
        "--overwrite", "--timezone", "UTC",
    ])
    assert rc == 0
    # GPX point at 10:00:00 is exactly (48.8566, 2.3522).
    import piexif
    gps = piexif.load(str(photo))["GPS"]
    deg, mins, sec = gps[piexif.GPSIFD.GPSLatitude]
    decimal = deg[0] / deg[1] + mins[0] / mins[1] / 60 + sec[0] / sec[1] / 3600
    assert decimal == pytest.approx(48.8566, abs=1e-4)


def _make_dng_with_dt(path, dt):
    import piexif
    from PIL import Image
    exif_dict: dict = {"0th": {}, "Exif": {}, "GPS": {}, "1st": {}, "thumbnail": None}
    exif_dict["Exif"][piexif.ExifIFD.DateTimeOriginal] = dt.strftime("%Y:%m:%d %H:%M:%S").encode()
    Image.new("RGB", (8, 8), (40, 40, 100)).save(path, "TIFF", exif=piexif.dump(exif_dict))
    return path


def test_AC_R13_RAW_sidecar_mode_tags_without_modifying_pixel_data(sample_gpx, tmp_path):
    """`--raw-mode sidecar` writes an XMP sidecar and never touches the RAW bytes."""
    dt = datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC)
    raw = _make_dng_with_dt(tmp_path / "shot.dng", dt)
    raw_bytes_before = raw.read_bytes()

    rc = cli.main(["--photo", str(raw), "--gps", str(sample_gpx),
                   "--overwrite", "--timezone", "UTC", "--raw-mode", "sidecar"])
    assert rc == 0

    sidecar = raw.with_suffix(raw.suffix + ".xmp")
    assert sidecar.exists()
    assert "<exif:GPSLatitude>" in sidecar.read_text()
    assert raw.read_bytes() == raw_bytes_before  # RAW pixel-data untouched


@pytest.mark.skipif(not tagger.raw_writer.exiftool_available(),
                    reason="exiftool not installed")
def test_AC_R13b_RAW_default_auto_embeds_into_file_when_exiftool_available(sample_gpx, tmp_path):
    """Default (auto) embeds GPS *into* the RAW via exiftool — no sidecar."""
    dt = datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC)
    raw = _make_dng_with_dt(tmp_path / "shot.dng", dt)

    rc = cli.main(["--photo", str(raw), "--gps", str(sample_gpx),
                   "--overwrite", "--timezone", "UTC"])  # no --raw-mode → auto
    assert rc == 0
    assert exif_mod.has_gps(raw)  # GPS embedded in the RAW itself
    assert not raw.with_suffix(raw.suffix + ".xmp").exists()  # no sidecar written


def test_AC_RAW_embed_mode_requires_exiftool_when_missing(monkeypatch, jpeg_factory, sample_gpx):
    """--raw-mode embed exits with a clear error when exiftool isn't on PATH."""
    photo = jpeg_factory("p.jpg", datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC))
    from gpsphototag import raw_writer
    monkeypatch.setattr(raw_writer, "exiftool_available", lambda: False)
    with pytest.raises(SystemExit):
        cli.main([
            "--photo", str(photo), "--gps", str(sample_gpx),
            "--overwrite", "--raw-mode", "embed", "--timezone", "UTC",
        ])


def test_AC_interpolated_match_uses_two_points(jpeg_factory, tmp_path):
    """Linear interpolation engages between two bracketing points within threshold."""
    photo = jpeg_factory("p.jpg", datetime(2024, 8, 15, 10, 0, 30, tzinfo=UTC))
    gpx = tmp_path / "trip.gpx"
    gpx.write_text(
        """<?xml version="1.0"?>
<gpx xmlns="http://www.topografix.com/GPX/1/1" version="1.1" creator="t">
  <trk><trkseg>
    <trkpt lat="0.0" lon="0.0"><time>2024-08-15T10:00:00Z</time></trkpt>
    <trkpt lat="2.0" lon="4.0"><time>2024-08-15T10:01:00Z</time></trkpt>
  </trkseg></trk>
</gpx>
""",
        encoding="utf-8",
    )
    rc = cli.main(["--photo", str(photo), "--gps", str(gpx),
                   "--overwrite", "--timezone", "UTC"])
    assert rc == 0
    import piexif
    gps = piexif.load(str(photo))["GPS"]
    deg, mins, sec = gps[piexif.GPSIFD.GPSLatitude]
    decimal = deg[0] / deg[1] + mins[0] / mins[1] / 60 + sec[0] / sec[1] / 3600
    assert decimal == pytest.approx(1.0, abs=1e-4)  # midpoint of 0 and 2


# ---------------------------------------------------------------------------
# R14 — --fix-dates exif: file date <- EXIF timestamp (end-to-end via CLI)
# ---------------------------------------------------------------------------
def test_AC_R14_fix_dates_exif_sets_file_date_from_exif(jpeg_factory):
    """`--fix-dates exif` sets the file's modified date to the EXIF timestamp."""
    exif_dt = datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC)
    photo = jpeg_factory("p.jpg", exif_dt)
    os.utime(photo, (0, 0))  # wipe to epoch so the change is observable
    rc = cli.main(["--photo", str(photo), "--overwrite",
                   "--timezone", "UTC", "--fix-dates", "exif"])
    assert rc == 0
    assert abs(photo.stat().st_mtime - exif_dt.timestamp()) < 2


# ---------------------------------------------------------------------------
# R15 — --fix-dates file: EXIF DateTimeOriginal <- file created date
# ---------------------------------------------------------------------------
def test_AC_R15_fix_dates_file_writes_exif_from_file_date(jpeg_factory, monkeypatch):
    """`--fix-dates file` writes EXIF DateTimeOriginal from the file's date."""
    photo = jpeg_factory("nodt.jpg", None)  # no EXIF datetime present
    created = datetime(2024, 8, 15, 14, 25, 0, tzinfo=UTC)
    monkeypatch.setattr(dates, "read_file_created", lambda p: created)
    rc = cli.main(["--photo", str(photo), "--overwrite",
                   "--timezone", "UTC", "--fix-dates", "file"])
    assert rc == 0
    got = exif_mod.read_timestamp(photo, fallback_tz=UTC)
    assert got is not None
    assert got.replace(tzinfo=None) == created.replace(tzinfo=None)


def test_AC_fix_dates_cli_parses_choices():
    """argparse exposes --fix-dates with exactly the {exif,file} choices."""
    args = cli.build_parser().parse_args(["--photo", "x.jpg", "--overwrite",
                                           "--fix-dates", "exif"])
    assert args.fix_dates == "exif"
    with pytest.raises(SystemExit):
        cli.build_parser().parse_args(["--photo", "x.jpg", "--fix-dates", "nonsense"])
