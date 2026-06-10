"""Render a modern density heatmap of where photos were taken.

Read-only counterpart to the tagging pipeline: walk the photos, read whatever
GPS EXIF they already carry, and draw a Google-Photos-style "glow" over a clean
Carto Positron basemap. Output is a high-resolution PNG.

Plotting deps (matplotlib, contextily) are optional — installed via the ``map``
extra. They are imported lazily so the core tool stays usable without them.
"""

from __future__ import annotations

import logging
import math
from pathlib import Path

from gpsphototag import exif

logger = logging.getLogger(__name__)

# Fixed figure width in inches; output pixel width is FIG_WIDTH_INCHES * dpi.
FIG_WIDTH_INCHES = 10.0
# Padding added around the data bounding box, as a fraction of its span.
_PAD_FRACTION = 0.15
# Minimum lon/lat span (degrees) so a single photo still gets a sane zoom.
_MIN_SPAN_DEG = 0.01
# Density grid resolution and the Gaussian splat radius (in grid cells).
_GRID_SIZE = 800
_SIGMA_PX = 7.0
# Per-photo marker styling (drawn on top of the glow so every location shows).
_MARKER_SIZE = 44
_MARKER_FILL = (0.85, 0.08, 0.40)  # magenta-red
_MARKER_ALPHA = 0.7
# Bounds on the displayed window's height/width ratio so the PNG isn't absurdly
# elongated; the deficient axis is widened (never squashed) to land in range.
_MIN_ASPECT = 0.5
_MAX_ASPECT = 1.8


class MapDependencyError(RuntimeError):
    """Raised when the optional map-rendering dependencies are not installed."""


def _load_deps():
    """Import matplotlib/contextily/numpy, or raise :class:`MapDependencyError`."""
    try:
        import contextily as cx
        import numpy as np
        from matplotlib import pyplot as plt
        from matplotlib.colors import LinearSegmentedColormap
    except ImportError as e:
        raise MapDependencyError(
            "Map rendering requires the 'map' extra. Install it with:\n"
            "    pip install 'gpsphototag[map]'"
        ) from e
    return cx, np, plt, LinearSegmentedColormap


def collect_coordinates(photos):
    """Return ``(coords, n_with_gps, n_without_gps)`` for ``photos``.

    ``coords`` is a list of ``(lat, lon)`` for every photo carrying usable GPS.
    """
    coords: list[tuple[float, float]] = []
    n_without = 0
    for path in photos:
        latlon = exif.read_gps(path)
        if latlon is None:
            n_without += 1
        else:
            coords.append(latlon)
    return coords, len(coords), n_without


def haversine_km(a, b) -> float:
    """Great-circle distance in km between two ``(lat, lon)`` points."""
    r = 6371.0088
    lat1, lon1 = math.radians(a[0]), math.radians(a[1])
    lat2, lon2 = math.radians(b[0]), math.radians(b[1])
    dlat, dlon = lat2 - lat1, lon2 - lon1
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


def cluster_coordinates(coords, *, threshold_km: float = 50.0):
    """Group ``coords`` into geographically distinct clusters.

    Single-linkage: two points join the same cluster if they are within
    ``threshold_km`` of each other (transitively). Returns a list of clusters
    (each a list of ``(lat, lon)``), sorted largest-first.
    """
    n = len(coords)
    parent = list(range(n))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i in range(n):
        for j in range(i + 1, n):
            if haversine_km(coords[i], coords[j]) <= threshold_km:
                parent[find(i)] = find(j)

    groups: dict[int, list] = {}
    for i in range(n):
        groups.setdefault(find(i), []).append(coords[i])
    return sorted(groups.values(), key=len, reverse=True)


def parse_cluster_selection(text: str, n_clusters: int):
    """Parse a cluster-selection string into 0-based indices, or None if invalid.

    ``""`` or ``"all"`` selects every cluster. ``"1,3"`` selects clusters 1 and 3
    (1-based for the user). Returns None on any out-of-range or non-numeric input
    so the caller can re-prompt or error.
    """
    t = text.strip().lower()
    if t in ("", "all", "a"):
        return list(range(n_clusters))
    try:
        idx = [int(p) - 1 for p in t.split(",") if p.strip()]
    except ValueError:
        return None
    if not idx or any(i < 0 or i >= n_clusters for i in idx):
        return None
    return sorted(set(idx))


def describe_location(lat: float, lon: float) -> str | None:
    """Best-effort place name for a coordinate via reverse geocoding, or None.

    Uses geopy's Nominatim if available and reachable; any failure (offline,
    rate-limited, not installed) returns None so callers fall back to coords.
    """
    try:
        from geopy.geocoders import Nominatim
        geocoder = Nominatim(user_agent="gpsphototag")
        loc = geocoder.reverse((lat, lon), language="en", zoom=10, timeout=5)
    except Exception:
        return None
    if loc is None:
        return None
    addr = getattr(loc, "raw", {}).get("address", {})
    city = (addr.get("city") or addr.get("town") or addr.get("village")
            or addr.get("municipality") or addr.get("county"))
    country = addr.get("country")
    parts = [p for p in (city, country) if p]
    return ", ".join(parts) if parts else None


def compute_extent(coords):
    """Return a padded ``(min_lon, min_lat, max_lon, max_lat)`` bounding box.

    A minimum span is enforced on each axis so a single photo or a tight
    cluster still produces a non-degenerate box the basemap can zoom to.
    """
    lats = [lat for lat, _ in coords]
    lons = [lon for _, lon in coords]
    min_lat, max_lat = min(lats), max(lats)
    min_lon, max_lon = min(lons), max(lons)

    lat_span = max(max_lat - min_lat, _MIN_SPAN_DEG)
    lon_span = max(max_lon - min_lon, _MIN_SPAN_DEG)
    lat_pad = lat_span * _PAD_FRACTION
    lon_pad = lon_span * _PAD_FRACTION
    lat_mid = (min_lat + max_lat) / 2.0
    lon_mid = (min_lon + max_lon) / 2.0

    return (
        lon_mid - lon_span / 2.0 - lon_pad,
        lat_mid - lat_span / 2.0 - lat_pad,
        lon_mid + lon_span / 2.0 + lon_pad,
        lat_mid + lat_span / 2.0 + lat_pad,
    )


def _lonlat_to_mercator(lon, lat):
    """Project decimal lon/lat to Web Mercator (EPSG:3857) metres."""
    import numpy as np

    r = 6378137.0
    x = np.radians(np.asarray(lon, dtype=float)) * r
    y = np.log(np.tan(np.pi / 4.0 + np.radians(np.asarray(lat, dtype=float)) / 2.0)) * r
    return x, y


def _density_grid(xs, ys, extent, *, size, sigma_px):
    """Accumulate a Gaussian splat per point onto a ``size``×``size`` grid.

    ``extent`` is ``(min_x, min_y, max_x, max_y)`` in the same units as
    ``xs``/``ys``. Returns a 2-D array indexed ``[row_y, col_x]`` (origin at the
    lower-left, matching ``imshow(origin="lower")``).
    """
    import numpy as np

    min_x, min_y, max_x, max_y = extent
    grid = np.zeros((size, size), dtype=float)
    width = max_x - min_x or 1.0
    height = max_y - min_y or 1.0

    # A square Gaussian kernel sized to the splat radius.
    radius = max(1, int(math.ceil(sigma_px * 3)))
    ax = np.arange(-radius, radius + 1)
    gx, gy = np.meshgrid(ax, ax)
    kernel = np.exp(-(gx**2 + gy**2) / (2.0 * sigma_px**2))

    for x, y in zip(np.atleast_1d(xs), np.atleast_1d(ys), strict=False):
        ci = int((x - min_x) / width * (size - 1))
        cj = int((y - min_y) / height * (size - 1))
        if not (0 <= ci < size and 0 <= cj < size):
            continue
        i0, i1 = max(0, ci - radius), min(size, ci + radius + 1)
        j0, j1 = max(0, cj - radius), min(size, cj + radius + 1)
        ki0, kj0 = i0 - (ci - radius), j0 - (cj - radius)
        grid[j0:j1, i0:i1] += kernel[kj0:kj0 + (j1 - j0), ki0:ki0 + (i1 - i0)]

    return grid


def _heatmap_cmap(LinearSegmentedColormap):
    """A modern, semi-transparent warm glow colormap.

    Colour ramps soft-amber → orange → red → magenta as density rises; alpha
    (the 4th channel of each RGBA stop) ramps from fully transparent at zero up
    to ~0.72 at the peak, so the basemap streets stay visible through the
    overlay — a translucent glow rather than an opaque blob.
    """
    stops = [
        (0.00, (1.00, 0.78, 0.30, 0.00)),  # transparent amber (no photos)
        (0.20, (1.00, 0.62, 0.18, 0.32)),  # faint orange
        (0.55, (0.95, 0.30, 0.18, 0.55)),  # red
        (1.00, (0.85, 0.05, 0.45, 0.72)),  # magenta (peak), still translucent
    ]
    return LinearSegmentedColormap.from_list("gpsphototag_heat", stops)


def _fit_aspect(x0, y0, x1, y1):
    """Widen the deficient axis of a mercator window into the aspect bounds.

    Returns ``(x0, y0, x1, y1)``. Only ever enlarges the window (keeping it
    centred), so every photo stays inside it and the map scale stays true.
    """
    w = x1 - x0
    h = y1 - y0
    aspect = h / w if w else 1.0
    if aspect > _MAX_ASPECT:  # too tall → widen horizontally
        new_w = h / _MAX_ASPECT
        cx_ = (x0 + x1) / 2.0
        x0, x1 = cx_ - new_w / 2.0, cx_ + new_w / 2.0
    elif aspect < _MIN_ASPECT:  # too wide → grow vertically
        new_h = w * _MIN_ASPECT
        cy_ = (y0 + y1) / 2.0
        y0, y1 = cy_ - new_h / 2.0, cy_ + new_h / 2.0
    return x0, y0, x1, y1


def render_heatmap(coords, out_path: Path, *, dpi: int = 200) -> None:
    """Render ``coords`` (``[(lat, lon), ...]``) to a heatmap PNG at ``out_path``.

    The map window is the (padded) bounding box of every photo, so it zooms to
    fit the whole set — tight for a single neighbourhood, wide for a road trip.

    Raises :class:`ValueError` if ``coords`` is empty and
    :class:`MapDependencyError` if the plotting deps are unavailable or tiles
    cannot be fetched.
    """
    if not coords:
        raise ValueError("Cannot render a map: no GPS coordinates were found.")

    cx, np, plt, LinearSegmentedColormap = _load_deps()

    lats = [lat for lat, _ in coords]
    lons = [lon for _, lon in coords]
    min_lon, min_lat, max_lon, max_lat = compute_extent(coords)

    (mx0, mx1), (my0, my1) = _lonlat_to_mercator([min_lon, max_lon], [min_lat, max_lat])
    x0, y0, x1, y1 = _fit_aspect(float(mx0), float(my0), float(mx1), float(my1))
    window = (x0, y0, x1, y1)

    aspect = (y1 - y0) / (x1 - x0)
    fig, ax = plt.subplots(figsize=(FIG_WIDTH_INCHES, FIG_WIDTH_INCHES * aspect))
    fig.subplots_adjust(left=0, right=1, top=1, bottom=0)
    ax.set_xlim(x0, x1)
    ax.set_ylim(y0, y1)
    ax.set_aspect("equal")
    ax.set_axis_off()

    try:
        cx.add_basemap(ax, crs="EPSG:3857", source=cx.providers.CartoDB.Positron,
                       attribution=False)
    except Exception as e:  # network/tile failure
        plt.close(fig)
        raise MapDependencyError(
            "Could not download map tiles — check your internet connection."
        ) from e

    xs, ys = _lonlat_to_mercator(lons, lats)
    grid = _density_grid(xs, ys, window, size=_GRID_SIZE, sigma_px=_SIGMA_PX)
    if grid.max() > 0:
        grid = grid / grid.max()
    ax.imshow(grid, origin="lower", extent=(x0, x1, y0, y1),
              cmap=_heatmap_cmap(LinearSegmentedColormap), zorder=3,
              interpolation="bilinear")

    # A crisp dot per photo on top of the glow, so individual locations (even a
    # single shot far from any cluster) are always visible. Overlapping dots in
    # busy spots darken naturally, reinforcing the density read.
    ax.scatter(xs, ys, s=_MARKER_SIZE, c=[_MARKER_FILL], alpha=_MARKER_ALPHA,
               edgecolors="white", linewidths=0.4, zorder=4)

    # Re-assert the window: add_basemap / imshow can nudge the limits.
    ax.set_xlim(x0, x1)
    ax.set_ylim(y0, y1)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_path, dpi=dpi, pad_inches=0)
    plt.close(fig)
