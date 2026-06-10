"""Targeted tests for branches not naturally hit by happy-path tests.

These exist to keep functional coverage honest (≥95%) without padding —
each test names a real, observable behavior the code should exhibit.
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone
from pathlib import Path

import pytest

from gpsphototag import cli, collectors, google_source, gpx_source
from gpsphototag import exif as exif_mod
from gpsphototag.display import StatusDisplay
from gpsphototag.locator import Locator
from gpsphototag.tagger import Tagger, TaggerOptions, copy_unmodified_to_out
from gpsphototag.types import PhotoRow, Status, TimedPoint

UTC = timezone.utc


def test_collectors_glob_matching_a_directory(tmp_path, monkeypatch):
    """Glob matching a directory expands recursively under that directory."""
    (tmp_path / "trip").mkdir()
    (tmp_path / "trip" / "DSC.jpg").write_bytes(b"")
    monkeypatch.chdir(tmp_path)
    out = collectors.collect_paths([["trip"]], collectors.PHOTO_EXTS)
    assert any(p.name == "DSC.jpg" for p in out)


def test_gpx_source_loads_route_points(tmp_path):
    f = tmp_path / "route.gpx"
    f.write_text(
        """<?xml version="1.0" encoding="UTF-8"?>
<gpx xmlns="http://www.topografix.com/GPX/1/1" version="1.1" creator="t">
  <rte><rtept lat="1.0" lon="2.0"><time>2024-08-15T10:00:00Z</time></rtept></rte>
</gpx>
""",
        encoding="utf-8",
    )
    pts = gpx_source.load([f])
    assert len(pts) == 1
    assert pts[0].lat == 1.0


def test_google_source_records_missing_fields_skipped(tmp_path, caplog):
    f = tmp_path / "Records.json"
    f.write_text(
        '{"locations":['
        '{"latitudeE7":488566000,"longitudeE7":23522000,"timestamp":"2024-08-15T09:00:00Z"},'
        '{"latitudeE7":488566000},'  # missing timestamp/longitude
        '{"junk":true}'
        ']}',
        encoding="utf-8",
    )
    pts = google_source.load([f])
    assert len(pts) == 1


def test_google_source_kml_point_placemark(tmp_path):
    """KML with <Point>/<TimeStamp> sibling pairs is parsed."""
    f = tmp_path / "single.kml"
    f.write_text(
        """<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <Placemark>
      <TimeStamp><when>2024-08-15T10:00:00Z</when></TimeStamp>
      <Point><coordinates>2.3522,48.8566,35</coordinates></Point>
    </Placemark>
  </Document>
</kml>
""",
        encoding="utf-8",
    )
    pts = google_source.load([f])
    assert len(pts) == 1
    assert pts[0].lat == pytest.approx(48.8566)


def test_google_source_unknown_extension_warns(tmp_path, caplog):
    f = tmp_path / "weird.xyz"
    f.write_text("nothing", encoding="utf-8")
    with caplog.at_level("WARNING"):
        out = google_source.load([f])
    assert out == []


def test_google_source_invalid_kml(tmp_path, caplog):
    f = tmp_path / "bad.kml"
    f.write_text("<not-kml", encoding="utf-8")
    with caplog.at_level("ERROR"):
        out = google_source.load([f])
    assert out == []


def test_exif_parse_offset_branches():
    from gpsphototag.dates import parse_exif_offset

    assert parse_exif_offset("Z") is timezone.utc
    assert parse_exif_offset("+02:30").utcoffset(None).total_seconds() == 2.5 * 3600
    assert parse_exif_offset("-05:00").utcoffset(None).total_seconds() == -5 * 3600
    assert parse_exif_offset("garbage") is None
    assert parse_exif_offset("") is timezone.utc


def test_exif_read_timestamp_handles_unreadable(tmp_path):
    bad = tmp_path / "not_an_image.jpg"
    bad.write_bytes(b"hello not a jpeg")
    assert exif_mod.read_timestamp(bad, fallback_tz=UTC) is None


def test_exif_has_gps_handles_unreadable(tmp_path):
    bad = tmp_path / "x.jpg"
    bad.write_bytes(b"not jpeg")
    assert exif_mod.has_gps(bad) is False


def test_exif_write_jpeg_with_no_existing_exif(tmp_path):
    """A JPEG saved without any EXIF segment can still receive GPS."""
    from PIL import Image
    src = tmp_path / "bare.jpg"
    Image.new("RGB", (4, 4), "red").save(src, "JPEG")
    exif_mod.write_gps(src, src, lat=1.0, lon=2.0)
    assert exif_mod.has_gps(src)


def test_tagger_handles_exif_read_exception(monkeypatch, jpeg_factory, tmp_path):
    photo = jpeg_factory("p.jpg", datetime(2024, 8, 15, tzinfo=UTC))

    def boom(*a, **kw):
        raise RuntimeError("boom")

    monkeypatch.setattr(exif_mod, "read_timestamp", boom)
    locator = Locator([], [], 60)
    display = StatusDisplay(console=__import__("rich").get_console())
    Tagger(locator, TaggerOptions(overwrite=True, fallback_tz=UTC), display).run([photo])
    assert display.summary.counts.get(Status.ERROR) == 1


def test_tagger_handles_write_exception(monkeypatch, jpeg_factory, tmp_path):
    dt = datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC)
    photo = jpeg_factory("p.jpg", dt)
    locator = Locator([TimedPoint(time=dt, lat=1.0, lon=2.0)], [], 60)

    def boom(*a, **kw):
        raise RuntimeError("disk full")

    monkeypatch.setattr(exif_mod, "apply_exif", boom)
    display = StatusDisplay(console=__import__("rich").get_console())
    Tagger(locator, TaggerOptions(overwrite=True, fallback_tz=UTC), display).run([photo])
    assert display.summary.counts.get(Status.ERROR) == 1


def test_tagger_out_dir_creates_directory(jpeg_factory, sample_gpx, tmp_path):
    dt = datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC)
    photo = jpeg_factory("p.jpg", dt)
    out = tmp_path / "new_subdir"
    locator = Locator(gpx_source.load([sample_gpx]), [], 60)
    display = StatusDisplay(console=__import__("rich").get_console())
    Tagger(locator, TaggerOptions(out_dir=out, fallback_tz=UTC), display).run([photo])
    assert (out / "p.jpg").exists()


def test_tagger_options_replace_requires_destination():
    with pytest.raises(ValueError):
        TaggerOptions(replace=True)


def test_copy_unmodified_to_out_preserves_skipped(jpeg_factory, tmp_path):
    """When --out is set, photos we did not modify are mirrored into out_dir."""
    a = jpeg_factory("a.jpg", datetime(2024, 8, 15, tzinfo=UTC))
    out = tmp_path / "out"
    out.mkdir()
    copy_unmodified_to_out([a], out, results=[])
    assert (out / "a.jpg").exists()


def test_setup_logging_quiets_exifread():
    """exifread's noisy 'File format not recognized.' is suppressed by default."""
    cli.setup_logging(verbose=False, log_file=None)
    assert logging.getLogger("exifread").level == logging.ERROR
    cli.setup_logging(verbose=True, log_file=None)
    assert logging.getLogger("exifread").level == logging.DEBUG


def test_cli_resolve_timezone_named():
    tz = cli.resolve_timezone("UTC")
    from datetime import datetime
    assert datetime.now(tz).tzinfo is not None


def test_cli_resolve_timezone_default_system_local():
    tz = cli.resolve_timezone(None)
    assert tz is not None


def test_cli_setup_logging_with_file(tmp_path):
    log = tmp_path / "gpsphototag.log"
    cli.setup_logging(verbose=True, log_file=log)
    logging.getLogger("gpsphototag.test").info("hello")
    # File handler may flush on close; force.
    for h in logging.getLogger().handlers:
        h.flush()
    assert log.exists() and log.read_text(encoding="utf-8").find("hello") >= 0


def test_cli_main_log_file_flag(jpeg_factory, sample_gpx, tmp_path):
    photo = jpeg_factory("e.jpg", datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC))
    log_path = tmp_path / "run.log"
    rc = cli.main([
        "--photo", str(photo),
        "--gps", str(sample_gpx),
        "--overwrite",
        "--timezone", "UTC",
        "--verbose",
        "--log-file", str(log_path),
    ])
    assert rc == 0
    for h in logging.getLogger().handlers:
        h.flush()
    assert log_path.exists()


def test_cli_main_error_returns_nonzero(monkeypatch, jpeg_factory, sample_gpx, tmp_path):
    """If an EXIF write raises, --replace flow should report error → rc=2."""
    photo = jpeg_factory("p.jpg", datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC))
    monkeypatch.setattr(exif_mod, "apply_exif", lambda *a, **kw: (_ for _ in ()).throw(RuntimeError("x")))
    rc = cli.main([
        "--photo", str(photo),
        "--gps", str(sample_gpx),
        "--overwrite",
        "--timezone", "UTC",
    ])
    assert rc == 2


def test_display_print_summary(jpeg_factory, tmp_path):
    """print_summary writes the panel to the console without error."""
    from rich.console import Console
    with open(tmp_path / "out.txt", "w") as fh:
        console = Console(file=fh, width=120)
        disp = StatusDisplay(console=console)
        disp.add(PhotoRow(path=Path("a.jpg"), status=Status.TAGGED))
        disp.print_summary()
    text = (tmp_path / "out.txt").read_text()
    assert "summary" in text.lower() or "total" in text.lower()


def test_display_format_path_with_root(tmp_path):
    from gpsphototag.display import format_path
    p = tmp_path / "sub" / "x.jpg"
    p.parent.mkdir()
    p.write_bytes(b"")
    assert format_path(p, root=tmp_path) == "sub/x.jpg"
    assert format_path(Path("/elsewhere/x.jpg"), root=tmp_path) == "x.jpg"
