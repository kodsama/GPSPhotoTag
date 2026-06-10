"""Heatmap generation: coordinate collection, extent math, PNG rendering."""

from __future__ import annotations

import builtins
from datetime import datetime, timezone

import pytest
from PIL import Image

from gpsphototag import exif as exif_mod
from gpsphototag import mapper

UTC = timezone.utc

# Tirana, Albania — the real-world test locale.
TIRANA = (41.3275, 19.8187)


COPENHAGEN = (55.6257, 12.6504)


def test_cluster_coordinates_separates_distant_groups():
    coords = [
        (41.327, 19.818), (41.330, 19.820), (41.333, 19.822),  # Tirana
        COPENHAGEN,                                             # far away
    ]
    clusters = mapper.cluster_coordinates(coords, threshold_km=50.0)
    assert len(clusters) == 2
    # Sorted largest-first: Tirana (3) then Copenhagen (1).
    assert len(clusters[0]) == 3
    assert len(clusters[1]) == 1
    assert clusters[1][0] == COPENHAGEN


def test_cluster_coordinates_single_group_when_all_close():
    coords = [(41.327, 19.818), (41.330, 19.820), (41.333, 19.822)]
    clusters = mapper.cluster_coordinates(coords, threshold_km=50.0)
    assert len(clusters) == 1
    assert len(clusters[0]) == 3


def test_haversine_km_known_distance():
    # Tirana → Copenhagen is roughly 1600 km.
    d = mapper.haversine_km((41.33, 19.82), COPENHAGEN)
    assert 1500 < d < 1750


@pytest.mark.parametrize("text,expected", [
    ("all", [0, 1, 2]),
    ("", [0, 1, 2]),
    ("1", [0]),
    ("1,3", [0, 2]),
    (" 2 , 1 ", [0, 1]),
])
def test_parse_cluster_selection_valid(text, expected):
    assert mapper.parse_cluster_selection(text, 3) == expected


@pytest.mark.parametrize("text", ["4", "0", "abc", "1,9", "-1"])
def test_parse_cluster_selection_invalid_returns_none(text):
    assert mapper.parse_cluster_selection(text, 3) is None


def test_collect_coordinates_counts(jpeg_factory):
    tagged = jpeg_factory("a.jpg", datetime(2024, 8, 15, tzinfo=UTC))
    exif_mod.write_gps(tagged, tagged, lat=TIRANA[0], lon=TIRANA[1])
    untagged = jpeg_factory("b.jpg", datetime(2024, 8, 15, tzinfo=UTC))

    coords, n_with, n_without = mapper.collect_coordinates([tagged, untagged])

    assert n_with == 1
    assert n_without == 1
    assert coords == [TIRANA] or coords[0] == pytest.approx(TIRANA, abs=1e-4)


def test_compute_extent_pads_around_points():
    coords = [(41.32, 19.81), (41.34, 19.83)]
    min_lon, min_lat, max_lon, max_lat = mapper.compute_extent(coords)
    # Box strictly contains the data with margin on every side.
    assert min_lon < 19.81 and max_lon > 19.83
    assert min_lat < 41.32 and max_lat > 41.34


def test_compute_extent_single_point_has_minimum_span():
    lat, lon = TIRANA
    min_lon, min_lat, max_lon, max_lat = mapper.compute_extent([(lat, lon)])
    # A lone photo still yields a non-degenerate box the basemap can zoom to.
    assert max_lon - min_lon > 1e-3
    assert max_lat - min_lat > 1e-3
    assert min_lon < lon < max_lon
    assert min_lat < lat < max_lat


def test_density_grid_peaks_at_point():
    # One point at the centre of a square extent → density peaks in the middle.
    extent = (-1.0, -1.0, 1.0, 1.0)  # min_x, min_y, max_x, max_y (mercator-ish)
    grid = mapper._density_grid([0.0], [0.0], extent, size=64, sigma_px=3.0)
    assert grid.shape == (64, 64)
    j, i = divmod(int(grid.argmax()), 64)
    assert 28 <= i <= 36
    assert 28 <= j <= 36


def test_render_heatmap_writes_png(monkeypatch, tmp_path):
    # No network: stub the basemap fetch so only our overlay is exercised.
    import contextily as cx
    monkeypatch.setattr(cx, "add_basemap", lambda *a, **k: None)

    coords = [(41.32, 19.81), (41.33, 19.82), (41.325, 19.815)]
    out = tmp_path / "map.png"
    mapper.render_heatmap(coords, out, dpi=50)

    assert out.exists()
    with Image.open(out) as img:
        assert img.format == "PNG"
        assert img.width == round(mapper.FIG_WIDTH_INCHES * 50)


def _airport_pixel_intensity(out_path, coords, isolated):
    """Return how far-from-white (0–255) the brightest pixel near ``isolated`` is."""
    import numpy as np

    im = np.asarray(Image.open(out_path).convert("RGB"))
    h, w, _ = im.shape
    min_lon, min_lat, max_lon, max_lat = mapper.compute_extent(coords)
    (mx0, mx1), (my0, my1) = mapper._lonlat_to_mercator(
        [min_lon, max_lon], [min_lat, max_lat])
    x0, y0, x1, y1 = mapper._fit_aspect(float(mx0), float(my0), float(mx1), float(my1))
    axp, ayp = mapper._lonlat_to_mercator([isolated[1]], [isolated[0]])
    px = int((float(axp[0]) - x0) / (x1 - x0) * (w - 1))
    py = int((1 - (float(ayp[0]) - y0) / (y1 - y0)) * (h - 1))
    patch = im[max(0, py - 4):py + 5, max(0, px - 4):px + 5].reshape(-1, 3)
    return int((255 - patch.min(axis=1)).max())


def test_render_marks_isolated_photo_visibly(monkeypatch, tmp_path):
    """A lone photo far from a busy cluster must still be clearly marked."""
    import contextily as cx
    monkeypatch.setattr(cx, "add_basemap", lambda *a, **k: None)

    busy = [(41.327 + 0.0003 * i, 19.818 + 0.0003 * i) for i in range(8)]
    isolated = (41.41, 19.71)
    coords = busy + [isolated]
    out = tmp_path / "m.png"
    mapper.render_heatmap(coords, out, dpi=80)

    assert _airport_pixel_intensity(out, coords, isolated) > 120


def test_render_heatmap_no_coords_raises(tmp_path):
    with pytest.raises(ValueError, match="no GPS"):
        mapper.render_heatmap([], tmp_path / "x.png", dpi=50)


def test_density_grid_skips_points_outside_extent():
    extent = (-1.0, -1.0, 1.0, 1.0)
    grid = mapper._density_grid([5.0], [5.0], extent, size=32, sigma_px=2.0)
    assert grid.max() == 0.0  # the lone point lies outside the grid


def test_fit_aspect_widens_tall_window():
    x0, y0, x1, y1 = mapper._fit_aspect(0.0, 0.0, 1.0, 10.0)
    assert (y1 - y0) == 10.0  # height unchanged
    assert (x1 - x0) == pytest.approx(10.0 / mapper._MAX_ASPECT)  # widened
    assert (x0 + x1) / 2 == pytest.approx(0.5)  # still centred


def test_fit_aspect_grows_wide_window():
    x0, y0, x1, y1 = mapper._fit_aspect(0.0, 0.0, 10.0, 1.0)
    assert (x1 - x0) == 10.0
    assert (y1 - y0) == pytest.approx(10.0 * mapper._MIN_ASPECT)


def test_fit_aspect_leaves_balanced_window_untouched():
    assert mapper._fit_aspect(0.0, 0.0, 1.0, 1.0) == (0.0, 0.0, 1.0, 1.0)


def _patch_nominatim(monkeypatch, reverse_result):
    import geopy.geocoders as g

    class FakeGeocoder:
        def __init__(self, *a, **k):
            pass

        def reverse(self, *a, **k):
            if isinstance(reverse_result, Exception):
                raise reverse_result
            return reverse_result

    monkeypatch.setattr(g, "Nominatim", FakeGeocoder)


def test_describe_location_returns_place_name(monkeypatch):
    class FakeLoc:
        raw = {"address": {"city": "Tirana", "country": "Albania"}}

    _patch_nominatim(monkeypatch, FakeLoc())
    assert mapper.describe_location(41.33, 19.82) == "Tirana, Albania"


def test_describe_location_none_when_no_result(monkeypatch):
    _patch_nominatim(monkeypatch, None)
    assert mapper.describe_location(0.0, 0.0) is None


def test_describe_location_none_on_error(monkeypatch):
    _patch_nominatim(monkeypatch, RuntimeError("offline"))
    assert mapper.describe_location(0.0, 0.0) is None


def test_render_heatmap_tile_failure_raises_dependency_error(monkeypatch, tmp_path):
    import contextily as cx

    def boom(*a, **k):
        raise RuntimeError("network down")

    monkeypatch.setattr(cx, "add_basemap", boom)
    with pytest.raises(mapper.MapDependencyError, match="tiles"):
        mapper.render_heatmap([(41.32, 19.81)], tmp_path / "x.png", dpi=50)


def test_load_deps_raises_friendly_error_when_missing(monkeypatch):
    real_import = builtins.__import__

    def fake_import(name, *args, **kwargs):
        if name == "contextily" or name.startswith("contextily."):
            raise ImportError("No module named 'contextily'")
        return real_import(name, *args, **kwargs)

    monkeypatch.setattr(builtins, "__import__", fake_import)
    with pytest.raises(mapper.MapDependencyError, match=r"pip install"):
        mapper._load_deps()
