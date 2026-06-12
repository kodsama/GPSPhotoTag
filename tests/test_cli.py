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


def test_map_mode_renders_png(jpeg_factory, tmp_path, monkeypatch):
    """--map reads existing GPS and renders, without needing a destination."""
    photo = jpeg_factory("m.jpg", datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC))
    exif_mod.write_gps(photo, photo, lat=41.3275, lon=19.8187)

    captured = {}

    def fake_render(coords, out_path, *, dpi, names=None):
        captured["coords"] = coords
        captured["out"] = out_path
        out_path.write_bytes(b"PNG")

    monkeypatch.setattr(cli.mapper, "render_heatmap", fake_render)
    out = tmp_path / "heat.png"
    rc = cli.main(["--photo", str(photo), "--map", str(out)])

    assert rc == 0
    assert captured["coords"] == [(pytest.approx(41.3275, abs=1e-4),
                                   pytest.approx(19.8187, abs=1e-4))]
    assert captured["out"] == out


def test_map_mode_cluster_selection_filters(jpeg_factory, tmp_path, monkeypatch):
    """Two distant locations → --map-clusters picks which to render."""
    t1 = jpeg_factory("t1.jpg", datetime(2024, 8, 15, tzinfo=UTC))
    exif_mod.write_gps(t1, t1, lat=41.327, lon=19.818)  # Tirana
    t2 = jpeg_factory("t2.jpg", datetime(2024, 8, 15, tzinfo=UTC))
    exif_mod.write_gps(t2, t2, lat=41.330, lon=19.820)  # Tirana
    cph = jpeg_factory("cph.jpg", datetime(2024, 8, 15, tzinfo=UTC))
    exif_mod.write_gps(cph, cph, lat=55.626, lon=12.650)  # Copenhagen

    monkeypatch.setattr(cli.mapper, "describe_location", lambda *a, **k: None)
    captured = {}
    monkeypatch.setattr(cli.mapper, "render_heatmap",
                        lambda coords, out, *, dpi, names=None: captured.update(coords=coords))

    rc = cli.main(["--photo", str(t1), str(t2), str(cph),
                   "--map", str(tmp_path / "m.png"), "--map-clusters", "1"])
    assert rc == 0
    # Cluster 1 is the largest (the two Tirana photos); Copenhagen excluded.
    assert len(captured["coords"]) == 2
    assert all(c[0] < 50 for c in captured["coords"])


def test_map_mode_non_interactive_includes_all(jpeg_factory, tmp_path, monkeypatch):
    """No --map-clusters and no TTY → every cluster is included."""
    t = jpeg_factory("t.jpg", datetime(2024, 8, 15, tzinfo=UTC))
    exif_mod.write_gps(t, t, lat=41.327, lon=19.818)
    cph = jpeg_factory("c.jpg", datetime(2024, 8, 15, tzinfo=UTC))
    exif_mod.write_gps(cph, cph, lat=55.626, lon=12.650)
    monkeypatch.setattr(cli.mapper, "describe_location", lambda *a, **k: None)
    monkeypatch.setattr(cli.sys.stdin, "isatty", lambda: False)
    calls = []
    monkeypatch.setattr(cli.mapper, "render_heatmap",
                        lambda coords, out, *, dpi, names=None: calls.append(list(coords)))

    rc = cli.main(["--photo", str(t), str(cph), "--map", str(tmp_path / "m.png")])
    assert rc == 0
    assert len(calls[0]) == 2  # the overview map includes both clusters


def test_map_mode_interactive_prompt_selects(jpeg_factory, tmp_path, monkeypatch):
    t1 = jpeg_factory("t1.jpg", datetime(2024, 8, 15, tzinfo=UTC))
    exif_mod.write_gps(t1, t1, lat=41.327, lon=19.818)
    t2 = jpeg_factory("t2.jpg", datetime(2024, 8, 15, tzinfo=UTC))
    exif_mod.write_gps(t2, t2, lat=41.330, lon=19.820)
    cph = jpeg_factory("c.jpg", datetime(2024, 8, 15, tzinfo=UTC))
    exif_mod.write_gps(cph, cph, lat=55.626, lon=12.650)
    monkeypatch.setattr(cli.mapper, "describe_location", lambda *a, **k: None)
    monkeypatch.setattr(cli.sys.stdin, "isatty", lambda: True)
    monkeypatch.setattr("builtins.input", lambda *a: "1")
    captured = {}
    monkeypatch.setattr(cli.mapper, "render_heatmap",
                        lambda coords, out, *, dpi, names=None: captured.update(coords=coords))

    rc = cli.main(["--photo", str(t1), str(t2), str(cph), "--map", str(tmp_path / "m.png")])
    assert rc == 0
    assert len(captured["coords"]) == 2  # cluster 1 = the two Tirana photos


def test_map_mode_interactive_gives_up_after_bad_input(jpeg_factory, tmp_path, monkeypatch):
    t = jpeg_factory("t.jpg", datetime(2024, 8, 15, tzinfo=UTC))
    exif_mod.write_gps(t, t, lat=41.327, lon=19.818)
    cph = jpeg_factory("c.jpg", datetime(2024, 8, 15, tzinfo=UTC))
    exif_mod.write_gps(cph, cph, lat=55.626, lon=12.650)
    monkeypatch.setattr(cli.mapper, "describe_location", lambda *a, **k: None)
    monkeypatch.setattr(cli.sys.stdin, "isatty", lambda: True)
    monkeypatch.setattr("builtins.input", lambda *a: "nonsense")

    rc = cli.main(["--photo", str(t), str(cph), "--map", str(tmp_path / "m.png")])
    assert rc == 1


def test_map_mode_invalid_cluster_selection_errors(jpeg_factory, tmp_path, monkeypatch):
    t1 = jpeg_factory("a.jpg", datetime(2024, 8, 15, tzinfo=UTC))
    exif_mod.write_gps(t1, t1, lat=41.327, lon=19.818)
    cph = jpeg_factory("b.jpg", datetime(2024, 8, 15, tzinfo=UTC))
    exif_mod.write_gps(cph, cph, lat=55.626, lon=12.650)
    monkeypatch.setattr(cli.mapper, "describe_location", lambda *a, **k: None)

    rc = cli.main(["--photo", str(t1), str(cph),
                   "--map", str(tmp_path / "m.png"), "--map-clusters", "9"])
    assert rc == 1


def test_map_mode_no_gps_returns_error(jpeg_factory, tmp_path):
    photo = jpeg_factory("nogps.jpg", datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC))
    rc = cli.main(["--photo", str(photo), "--map", str(tmp_path / "x.png")])
    assert rc == 1


def test_map_mode_rejects_writing_flags(jpeg_factory, tmp_path):
    photo = jpeg_factory("c.jpg", datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC))
    with pytest.raises(SystemExit):
        cli.main(["--photo", str(photo), "--map", str(tmp_path / "x.png"),
                  "--overwrite"])


def test_map_mode_missing_deps_returns_error(jpeg_factory, tmp_path, monkeypatch):
    photo = jpeg_factory("d.jpg", datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC))
    exif_mod.write_gps(photo, photo, lat=41.3, lon=19.8)

    def boom(*a, **k):
        raise cli.mapper.MapDependencyError("install the map extra")

    monkeypatch.setattr(cli.mapper, "render_heatmap", boom)
    rc = cli.main(["--photo", str(photo), "--map", str(tmp_path / "x.png")])
    assert rc == 1


@pytest.mark.parametrize("bad", ["0", "-50", "10", "5000", "abc"])
def test_map_dpi_out_of_range_rejected(bad):
    with pytest.raises(SystemExit):
        _parse(["--photo", "x.jpg", "--map", "m.png", "--map-dpi", bad])


def test_map_dpi_in_range_accepted():
    args = _parse(["--photo", "x.jpg", "--map", "m.png", "--map-dpi", "300"])
    assert args.map_dpi == 300


def test_invalid_timezone_friendly_error(jpeg_factory, capsys):
    photo = jpeg_factory("tz.jpg", datetime(2024, 8, 15, 10, 0, 0, tzinfo=UTC))
    with pytest.raises(SystemExit):
        cli.main(["--photo", str(photo), "--overwrite", "--timezone", "Not/AZone"])
    assert "timezone" in capsys.readouterr().err.lower()


def _make_raw_pair_dir(tmp_path):
    """A dir with one paired RAW+JPG and one orphan RAW (plus its sidecar)."""
    (tmp_path / "pair.raf").write_bytes(b"x")
    (tmp_path / "pair.jpg").write_bytes(b"x")
    (tmp_path / "orphan.raf").write_bytes(b"x")
    (tmp_path / "orphan.raf.xmp").write_bytes(b"x")
    return tmp_path


def test_prune_raw_deletes_orphans_keeps_pairs(tmp_path):
    d = _make_raw_pair_dir(tmp_path)
    rc = cli.main(["--photo", str(d), "--prune-raw"])
    assert rc == 0
    assert not (d / "orphan.raf").exists()
    assert not (d / "orphan.raf.xmp").exists()
    assert (d / "pair.raf").exists()
    assert (d / "pair.jpg").exists()


def test_prune_raw_dry_run_deletes_nothing(tmp_path):
    d = _make_raw_pair_dir(tmp_path)
    rc = cli.main(["--photo", str(d), "--prune-raw", "--dry-run"])
    assert rc == 0
    assert (d / "orphan.raf").exists()
    assert (d / "orphan.raf.xmp").exists()


def test_prune_raw_no_orphans_succeeds(tmp_path):
    (tmp_path / "pair.raf").write_bytes(b"x")
    (tmp_path / "pair.jpg").write_bytes(b"x")
    assert cli.main(["--photo", str(tmp_path), "--prune-raw"]) == 0


@pytest.mark.parametrize("extra", [["--overwrite"], ["--map", "m.png"],
                                   ["--gps", "track.gpx"]])
def test_prune_raw_rejects_conflicting_flags(tmp_path, extra):
    (tmp_path / "orphan.raf").write_bytes(b"x")
    with pytest.raises(SystemExit):
        cli.main(["--photo", str(tmp_path), "--prune-raw", *extra])
