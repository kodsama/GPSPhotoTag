"""CLI: argparse, destination validation, smoke end-to-end."""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from gpsphototag import cli
from gpsphototag import exif as exif_mod

UTC = timezone.utc


def _parse(argv):
    return cli.build_parser().parse_args(argv)


def test_parser_repeated_photo_arg():
    args = _parse(["--photo", "a.jpg", "b.jpg", "--photo", "c.jpg", "--overwrite"])
    assert args.photo == [["a.jpg", "b.jpg"], ["c.jpg"]]


def test_parser_raw_mode_defaults_to_auto():
    """RAW writes default to 'auto' (embed into the file when possible)."""
    assert _parse(["--photo", "x.raf", "--overwrite"]).raw_mode == "auto"


def test_validate_requires_destination():
    args = _parse(["--photo", "x.jpg"])
    assert cli.validate_destination(args) is not None


def test_validate_out_and_overwrite_conflict(tmp_path):
    args = _parse(["--photo", "x.jpg", "--out", str(tmp_path), "--overwrite"])
    assert "mutually exclusive" in cli.validate_destination(args)


def test_validate_replace_needs_destination():
    args = _parse(["--photo", "x.jpg", "--replace"])
    err = cli.validate_destination(args)
    assert err and "--replace" in err


def test_validate_dry_run_skips_destination_check():
    args = _parse(["--photo", "x.jpg", "--dry-run"])
    assert cli.validate_destination(args) is None


def test_validate_overwrite_ok():
    args = _parse(["--photo", "x.jpg", "--overwrite"])
    assert cli.validate_destination(args) is None


def test_main_end_to_end_overwrites_in_place(jpeg_factory, sample_gpx, tmp_path, capsys):
    """End-to-end: a photo at 10:00:00 + GPX with a point at 10:00:00 → tagged."""
    photo = jpeg_factory("e2e.jpg", datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC))
    rc = cli.main([
        "--photo", str(photo),
        "--gps", str(sample_gpx),
        "--overwrite",
        "--timezone", "UTC",
    ])
    assert rc == 0
    assert exif_mod.has_gps(photo)


def test_main_dry_run_does_not_write(jpeg_factory, sample_gpx):
    photo = jpeg_factory("dry.jpg", datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC))
    rc = cli.main([
        "--photo", str(photo),
        "--gps", str(sample_gpx),
        "--dry-run",
        "--timezone", "UTC",
    ])
    assert rc == 0
    assert not exif_mod.has_gps(photo)


def test_main_no_photos_returns_error(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    rc = cli.main(["--photo", "nothing-here-*.jpg", "--overwrite"])
    assert rc == 1


def test_main_no_gps_no_match(jpeg_factory, tmp_path):
    photo = jpeg_factory("e.jpg", datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC))
    rc = cli.main(["--photo", str(photo), "--overwrite", "--timezone", "UTC"])
    assert rc == 0
    assert not exif_mod.has_gps(photo)


def test_main_destination_error_exits(jpeg_factory):
    photo = jpeg_factory("p.jpg", datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC))
    with pytest.raises(SystemExit):
        cli.main(["--photo", str(photo)])
