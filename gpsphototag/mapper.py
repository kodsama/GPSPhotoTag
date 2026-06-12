"""Render a modern density heatmap of where photos were taken.

Read-only counterpart to the tagging pipeline: walk the photos, read whatever
GPS EXIF they already carry, and draw a Google-Photos-style "glow" over a clean
Carto Positron basemap. Output is a high-resolution PNG.

Plotting deps (matplotlib, contextily) are optional — installed via the ``map``
extra. They are imported lazily so the core tool stays usable without them.

Privacy: rendering makes two kinds of network requests — basemap tiles are
fetched from CARTO for the photos' bounding box, and cluster names come from
OSM Nominatim reverse geocoding (cluster centroids only, never per photo).
Nothing else leaves the machine.
"""

from __future__ import annotations

import logging
import math
import re
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
# Auto-zoom: when photos span more than the trigger, emit a zoom map per region.
_ZOOM_TRIGGER_KM = 2.0
_ZOOM_REGION_KM = 1.5
# Photos within this distance share one filename-range label.
_LABEL_SPOT_KM = 0.25
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
    coords, _names, n_with, n_without = collect_located(photos)
    return coords, n_with, n_without


def haversine_km(a, b) -> float:
    """Great-circle distance in km between two ``(lat, lon)`` points."""
    r = 6371.0088
    lat1, lon1 = math.radians(a[0]), math.radians(a[1])
    lat2, lon2 = math.radians(b[0]), math.radians(b[1])
    dlat, dlon = lat2 - lat1, lon2 - lon1
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    # Clamp: float rounding can push h fractionally past 1.0 for near-antipodal
    # points, which would take sqrt(h) outside asin's domain.
    return 2 * r * math.asin(min(1.0, math.sqrt(h)))


def cluster_indices(coords, threshold_km: float = 50.0):
    """Single-linkage cluster ``coords``; return index groups, largest-first.

    Two points join the same group when within ``threshold_km`` (transitively).
    Each group is a list of indices into ``coords``, in ascending order; groups
    are sorted largest-first. Working in indices lets callers keep parallel data
    (e.g. filenames) aligned with the coordinates.
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
        groups.setdefault(find(i), []).append(i)
    return sorted(groups.values(), key=len, reverse=True)


def cluster_coordinates(coords, *, threshold_km: float = 50.0):
    """Group ``coords`` into geographically distinct clusters, largest-first.

    Each cluster is a list of ``(lat, lon)``. See :func:`cluster_indices`.
    """
    return [[coords[i] for i in g] for g in cluster_indices(coords, threshold_km)]


_TRAILING_NUM = re.compile(r"^(.*?)(\d+)$")


def _split_name(stem: str):
    """Split a filename stem into ``(prefix, number, width)``; number is None if
    there is no trailing digit run."""
    m = _TRAILING_NUM.match(stem)
    if not m:
        return stem, None, 0
    return m.group(1), int(m.group(2)), len(m.group(2))


def collapse_filenames(stems, *, max_len: int = 32) -> str:
    """Collapse filename stems into compact ranges.

    Consecutive numbers under a shared prefix become ``PREFIX0001-0003``; gaps
    split into ``…, 0005``; distinct prefixes join with ``; ``. The result is
    truncated to ``max_len`` (with an ellipsis) so labels stay readable.
    """
    groups: dict[str, list] = {}
    order: list[str] = []
    for s in stems:
        prefix, num, width = _split_name(s)
        if prefix not in groups:
            groups[prefix] = []
            order.append(prefix)
        groups[prefix].append((num, width))

    group_strs = []
    for prefix in order:
        entries = groups[prefix]
        nums = sorted({n for n, _ in entries if n is not None})
        if not nums:
            group_strs.append(prefix)
            continue
        width = max(w for n, w in entries if n is not None)
        runs = []
        start = prev = nums[0]
        for n in nums[1:]:
            if n == prev + 1:
                prev = n
                continue
            runs.append((start, prev))
            start = prev = n
        runs.append((start, prev))
        parts = []
        for k, (s_, e_) in enumerate(runs):
            tok = f"{prefix}{s_:0{width}d}" if k == 0 else f"{s_:0{width}d}"
            if e_ != s_:
                tok += f"-{e_:0{width}d}"
            parts.append(tok)
        group_strs.append(", ".join(parts))

    result = "; ".join(group_strs)
    if len(result) > max_len:
        result = result[:max_len - 1].rstrip(", ") + "…"
    return result


def area_labels(coords, names, *, threshold_km: float = 0.25):
    """Return ``(lat, lon, text)`` labels — one per spot of nearby photos.

    Photos within ``threshold_km`` form a spot; its label is the centroid plus
    the collapsed filename range of the photos in it.
    """
    labels = []
    for group in cluster_indices(coords, threshold_km):
        lat = sum(coords[i][0] for i in group) / len(group)
        lon = sum(coords[i][1] for i in group) / len(group)
        labels.append((lat, lon, collapse_filenames([names[i] for i in group])))
    return labels


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

    Privacy: this sends the (cluster-centroid) coordinate to the public OSM
    Nominatim service. Only called for cluster naming, never per photo.
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


def collect_located(photos):
    """Like :func:`collect_coordinates` but also returns parallel filename stems.

    Returns ``(coords, names, n_with_gps, n_without_gps)`` where ``coords`` is
    ``[(lat, lon), ...]`` and ``names[i]`` is the stem of the photo at
    ``coords[i]`` — kept aligned for filename-range labels.
    """
    coords: list[tuple[float, float]] = []
    names: list[str] = []
    n_without = 0
    for path in photos:
        latlon = exif.read_gps(path)
        if latlon is None:
            n_without += 1
        else:
            coords.append(latlon)
            names.append(path.stem)
    return coords, names, len(coords), n_without


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


# Web Mercator is undefined at the poles; this is its conventional latitude cap.
_MAX_MERCATOR_LAT = 85.05113


def _lonlat_to_mercator(lon, lat):
    """Project decimal lon/lat to Web Mercator (EPSG:3857) metres.

    Inputs are clamped to the projection's valid domain (lat ±85.05113°,
    lon ±180°) so near-pole coordinates can't produce infinities.
    """
    import numpy as np

    r = 6378137.0
    lon_a = np.clip(np.asarray(lon, dtype=float), -180.0, 180.0)
    lat_a = np.clip(np.asarray(lat, dtype=float), -_MAX_MERCATOR_LAT, _MAX_MERCATOR_LAT)
    x = np.radians(lon_a) * r
    y = np.log(np.tan(np.pi / 4.0 + np.radians(lat_a) / 2.0)) * r
    return x, y


def _density_grid(xs, ys, extent, *, size, sigma_px):
    """Accumulate a Gaussian splat per point onto a ``size`` x ``size`` grid.

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


def _bbox_diagonal_km(coords) -> float:
    """Great-circle distance across the bounding box of ``coords``."""
    lats = [c[0] for c in coords]
    lons = [c[1] for c in coords]
    return haversine_km((min(lats), min(lons)), (max(lats), max(lons)))


def render_maps(coords, out_path: Path, *, dpi: int = 200, names=None) -> list[Path]:
    """Render the overview map, plus a zoomed map per region when spread out.

    Always writes the overview to ``out_path``. When the photos span more than
    ``_ZOOM_TRIGGER_KM`` and fall into multiple regions, also writes one
    zoomed-in PNG per region as ``<stem>-zoom<N><suffix>``. ``names`` (parallel
    to ``coords``) enables filename-range labels on every map. Returns the list
    of written paths.
    """
    written = [out_path]
    render_heatmap(coords, out_path, dpi=dpi, names=names)

    if _bbox_diagonal_km(coords) > _ZOOM_TRIGGER_KM:
        regions = cluster_indices(coords, _ZOOM_REGION_KM)
        if len(regions) > 1:
            for n, region in enumerate(regions, 1):
                zoom_coords = [coords[i] for i in region]
                zoom_names = [names[i] for i in region] if names is not None else None
                zoom_path = out_path.with_name(
                    f"{out_path.stem}-zoom{n}{out_path.suffix}")
                render_heatmap(zoom_coords, zoom_path, dpi=dpi, names=zoom_names)
                written.append(zoom_path)
    return written


def _add_basemap(cx, plt, fig, ax) -> None:
    """Draw the CARTO Positron basemap; MapDependencyError on tile failure."""
    try:
        cx.add_basemap(ax, crs="EPSG:3857", source=cx.providers.CartoDB.Positron,
                       attribution=False)
    except Exception as e:  # network/tile failure
        plt.close(fig)
        raise MapDependencyError(
            "Could not download map tiles — check your internet connection."
        ) from e


def _annotate_areas(ax, coords, names) -> None:
    """Add one filename-range label per spot of nearby photos."""
    for lat, lon, text in area_labels(coords, names, threshold_km=_LABEL_SPOT_KM):
        (lx,), (ly,) = _lonlat_to_mercator([lon], [lat])
        ax.annotate(
            text, (float(lx), float(ly)), xytext=(0, 7),
            textcoords="offset points", ha="center", va="bottom",
            fontsize=6.5, color="#222222", zorder=5,
            bbox={"boxstyle": "round,pad=0.2", "facecolor": "white",
                  "edgecolor": "none", "alpha": 0.65},
        )


def render_heatmap(coords, out_path: Path, *, dpi: int = 200, names=None) -> None:
    """Render ``coords`` (``[(lat, lon), ...]``) to a heatmap PNG at ``out_path``.

    The map window is the (padded) bounding box of every photo, so it zooms to
    fit the whole set — tight for a single neighbourhood, wide for a road trip.
    ``names`` (parallel to ``coords``) adds per-area filename-range labels.

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

    _add_basemap(cx, plt, fig, ax)

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

    if names is not None:
        _annotate_areas(ax, coords, names)

    # Re-assert the window: add_basemap / imshow can nudge the limits.
    ax.set_xlim(x0, x1)
    ax.set_ylim(y0, y1)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_path, dpi=dpi, pad_inches=0)
    plt.close(fig)
