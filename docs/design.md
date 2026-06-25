# Stunda — Design Spec

**Date:** 2026-05-28
**Status:** Implemented — kept as the historical v0 design. Features shipped
since this spec was written: RAW read/write support (`--raw-mode`, XMP
sidecars / exiftool embedding), date fixing (`--fix-dates`), heatmap
rendering (`--map`, `--map-dpi`, `--map-clusters`, `--map-names`), Google's
2024+ semanticSegments Timeline format, and orphan-RAW pruning
(`--prune-raw`). The [README](../README.md) is the up-to-date reference.
**Author:** Kodsama (Alexandre Martins)

## 1. Purpose

A Python CLI that writes GPS EXIF tags into photos using GPX tracks
or Google location history as a fallback. Designed for personal use:
tag travel photos with the location your phone was at, when you took
each shot.

## 2. Scope

In scope:

- Reading photo timestamps from EXIF (`DateTimeOriginal`,
  `OffsetTimeOriginal`).
- Selecting photos and GPS files via repeated flags, globs, single
  files, or directories (recursive).
- Resolving location with GPX tracks first, then Google location
  history (Takeout `Records.json` and per-day Timeline exports).
- Writing GPS EXIF to JPEG, HEIC, and PNG.
- Safe-by-default writes: separate flags to enable in-place
  modification (`--overwrite`) and to overwrite existing GPS bytes
  (`--replace`).
- Clear terminal status (live table + final summary) and structured
  logging.

Out of scope (YAGNI):

- Live querying of Google APIs (the Timeline API is deprecated;
  history is on-device or Takeout-only).
- RAW formats (CR2/NEF/ARW/DNG). May add later via `exiftool`.
- Video files.
- Reverse geocoding (city/country tags).

## 3. CLI

```
stunda --photo PHOTO [PHOTO ...] [--photo ...]
         [--gps GPX [GPX ...] [--gps ...]]
         [--maps-history PATH [PATH ...]]
         [--out DIR]
         [--overwrite] [--replace]
         [--max-time-diff SECONDS]   (default 300)
         [--timezone TZ]             (default: system local)
         [--dry-run]
         [--verbose] [--log-file PATH]
```

### Argument behavior

- **`--photo` / `-p`** (required, repeatable, `nargs='+'`). Each
  value is resolved as:
  - existing file → kept as-is,
  - existing directory → recursive scan for supported extensions,
  - otherwise → treated as a glob pattern, expanded relative to CWD.

  Supported extensions: `.jpg .jpeg .heic .heif .png` (case-insensitive).
  Both `--photo "DSC*.jpg"` (quoted, expanded internally) and
  `--photo DSC*.jpg` (shell-expanded into multiple values) work.

- **`--gps` / `-g`** (repeatable, same resolution rules). Extension
  filter: `.gpx`.

- **`--maps-history` / `-m`** (repeatable, same resolution rules).
  Auto-detects per file:
  - JSON whose top-level shape matches Takeout `Records.json`
    (`{"locations": [...]}`) → Takeout parser.
  - JSON whose shape matches Timeline per-day export
    (`{"timelineObjects": [...]}` or similar) → Timeline JSON parser.
  - `.kml` → Timeline KML parser.

- **`--out` / `-o`**: output directory; created if missing. Photo
  basenames are preserved. If the source set contains duplicate
  basenames from different directories, the parent directory name is
  prepended to disambiguate.

- **`--overwrite`**: required to modify originals in place (no
  `--out`). Without `--overwrite` *and* without `--out`, the program
  exits with an error before touching any file.

- **`--replace`**: when a photo already contains GPS EXIF, overwrite
  it. Without `--replace`, such photos are skipped with status
  `already_tagged`.

- **`--max-time-diff`**: max acceptable seconds between photo time
  and the GPS point(s). Default `300` (5 min).

- **`--timezone`**: IANA TZ name used when EXIF lacks
  `OffsetTimeOriginal`. Default: system local timezone via
  `tzlocal`. Can also be passed as `UTC`.

- **`--dry-run`**: locate and report without writing.

- **`--verbose` / `-v`**: console log level → DEBUG (default INFO).

- **`--log-file`**: optional file path; INFO+ written there
  regardless of `--verbose`.

### Argument validation (errors)

| Condition | Exit code | Message |
|---|---|---|
| neither `--out` nor `--overwrite` | 2 | "Specify --out DIR or --overwrite to allow modifying photos." |
| both `--out` and `--overwrite` | 2 | "--out and --overwrite are mutually exclusive." |
| `--replace` with neither `--out` nor `--overwrite` | 2 | "--replace requires --out or --overwrite." |
| no photo paths resolved | 1 | "No photos matched --photo arguments." |
| no GPS sources resolved AND `--maps-history` empty | warning, continue | "No GPS sources provided; only photos already tagged will be reported." |

## 4. Architecture

```
            ┌──────────────┐
            │   cli.py     │  argparse, setup_logging, runs Tagger
            └──────┬───────┘
                   │
       ┌───────────┴───────────┐
       │                       │
┌──────▼──────────┐    ┌───────▼─────────┐
│ photo_collector │    │  gps_collector  │     resolve paths
└──────┬──────────┘    └───────┬─────────┘
       │                       │
┌──────▼────────────────────────▼─────────────┐
│                   tagger.py                  │   orchestration
│  for photo in photos:                        │
│    ts = exif.read_timestamp(photo)           │
│    loc = locator.locate(ts)                  │
│    if loc and writable: exif.write_gps(...)  │
│    display.update(row)                       │
└──────┬───────────────────────────────────────┘
       │
┌──────▼──────────┐    uses
│   locator.py    │ ─────────► gpx_source.py
│                 │ ─────────► google_source.py
└─────────────────┘
```

### Module responsibilities

- **`photo_collector.collect(values: list[list[str]]) -> list[Path]`**
  Resolves repeated `--photo` flags into a flat, de-duplicated,
  sorted list of photo paths. Each value resolves as file, dir, or
  glob. Pure function over the filesystem.

- **`gps_collector.collect(values: list[list[str]]) -> list[Path]`**
  Same, but filters to `.gpx`.

- **`exif.read_timestamp(path: Path, fallback_tz: tzinfo) -> datetime`**
  Returns timezone-aware datetime. Reads `DateTimeOriginal` and
  `OffsetTimeOriginal`; if no offset is present, applies `fallback_tz`.

- **`exif.has_gps(path: Path) -> bool`**
  Returns True if any of GPSLatitude/GPSLongitude tags are present
  and parse to a finite number.

- **`exif.write_gps(src: Path, dst: Path, lat: float, lon: float)`**
  Writes GPS EXIF. Per-format strategy:
  - JPEG: `piexif.insert(piexif.dump(...), src_bytes)` → write to dst.
    Lossless re-tag (no re-encoding of pixel data).
  - HEIC: load via `pillow_heif` + Pillow, save with `exif=` bytes.
    Documents that this re-encodes; README notes the caveat.
  - PNG: Pillow `Image.save(..., exif=...)` (eXIf chunk).

- **`gpx_source.load(paths: list[Path]) -> list[TimedPoint]`**
  Parses all GPX files with `gpxpy`, flattens track points,
  returns a time-sorted list of `TimedPoint(time: datetime, lat,
  lon)`.

- **`google_source.load(paths: list[Path]) -> list[TimedPoint]`**
  Auto-detects each path:
  - Takeout `Records.json` → iterate `locations[]`, convert E7
    lat/lon and timestamp.
  - Timeline per-day JSON → walk `timelineObjects[]` extracting
    `activitySegment.startLocation` / `endLocation` and
    `placeVisit.location`, plus `simplifiedRawPath.points[]` if
    present.
  - Timeline KML → parse `<Placemark><gx:Track>` /
    `<Placemark><Point>` with `<when>` siblings.

  Returns one merged, time-sorted `list[TimedPoint]`.

- **`locator.Locator(gpx_points, google_points, max_time_diff)`**
  - `.locate(ts: datetime) -> LocationResult | None`
  - Tries `gpx_points` first via `_interp_or_nearest`:
    - exact match (≤1 s) → method=`exact`.
    - bracketing pair, both within threshold → method=`interpolated`,
      linear interpolation in time on lat and lon.
    - else → fall through.
  - If no GPX hit, same logic on `google_points`.
  - `LocationResult(lat, lon, source: "gpx"|"google", method,
    time_diff_seconds)` or None.

- **`tagger.Tagger(...)`**
  - `.run(photos)`: iterates, builds per-photo row, writes via
    `exif.write_gps` honoring `--out`/`--overwrite`/`--replace`/
    `--dry-run`, and feeds `display.update(row)`.

- **`display.StatusDisplay`**
  - `rich.live.Live` wrapping a `rich.table.Table` with columns:
    `Photo | Time | Source | Coords | Status`.
  - Statuses: `tagged` (green), `interpolated` (green), `replaced`
    (yellow), `already_tagged` (yellow, skipped), `no_gps` (red),
    `error` (magenta), `dry_run` (cyan).
  - `.summary()` prints a panel with totals per status.

- **`cli.setup_logging(level, log_file)`**
  - Root logger configured once.
  - Console: `RichHandler(level=level)`.
  - File (if `--log-file`): `FileHandler(level=INFO)` with
    `%(asctime)s %(levelname)s %(name)s %(message)s`.

### Data types

```python
@dataclass(frozen=True)
class TimedPoint:
    time: datetime       # tz-aware, UTC normalized
    lat: float
    lon: float

@dataclass(frozen=True)
class LocationResult:
    lat: float
    lon: float
    source: Literal["gpx", "google"]
    method: Literal["exact", "interpolated"]
    time_diff_seconds: float

@dataclass(frozen=True)
class PhotoRow:
    path: Path
    timestamp: datetime | None
    location: LocationResult | None
    status: str
    detail: str = ""
```

## 5. Algorithm details

### Time matching with interpolation

Input: sorted `points`, target `ts`, threshold `Δ`.

```
i = bisect_left([p.time for p in points], ts)
candidates = [points[i-1] if i > 0 else None,
              points[i]   if i < len(points) else None]

# exact?
for p in candidates:
    if p and abs((p.time - ts).total_seconds()) <= 1:
        return exact(p)

# both sides within threshold?
prev, nxt = candidates
if prev and nxt and (ts - prev.time).total_seconds() <= Δ \
                and (nxt.time - ts).total_seconds() <= Δ:
    α = (ts - prev.time) / (nxt.time - prev.time)
    return interpolated(prev + α*(nxt - prev))

return None
```

Note: no extrapolation. If only one side is within threshold, we
return None — keeps fallback behavior predictable. A future option
could add `--allow-nearest` to fall back to nearest-within-threshold;
deferred.

### EXIF GPS encoding

We write:
- `GPSLatitudeRef` (N/S), `GPSLatitude` (deg/min/sec rationals)
- `GPSLongitudeRef` (E/W), `GPSLongitude`
- `GPSMapDatum` = "WGS-84"
- `GPSDateStamp`, `GPSTimeStamp` from the source point's time
  (UTC), so the EXIF GPS time field reflects when the location was
  recorded.

## 6. Error handling

- **Per-photo errors are isolated**: a malformed EXIF on photo 17
  must not stop photo 18. Caught at `Tagger.run` per iteration,
  logged, status = `error`, summary counts include them.
- **Boundary failures are loud**: unparseable `Records.json` aborts
  the run with a clear message (not silently skipped).
- **Unknown EXIF tz**: log a WARNING once per run when falling back
  to `--timezone` / system local.

## 7. Tests

Testing principle: every behavior change gets a test that
would fail without the change. Pytest, fixtures under
`tests/fixtures/`.

| Module | Key tests |
|---|---|
| `photo_collector` | file, dir-recursive, glob, ext filter, dedup, sort |
| `gps_collector` | same, plus `.gpx`-only filter |
| `exif` | round-trip on a real tiny JPEG fixture; `has_gps` true/false; PNG read; tz parsing with/without `OffsetTimeOriginal` |
| `gpx_source` | parse → sorted; merges multiple files |
| `google_source` | Records.json fixture; Timeline JSON fixture; KML fixture; auto-detect |
| `locator` | exact match, interpolation math, threshold filter, GPX precedence over Google, returns None when nothing close |
| `tagger` | `--replace` semantics; `--overwrite` + `--out` mutually exclusive; `--dry-run` writes nothing; `already_tagged` skip path |
| `cli` | argparse validation matrix (the table in §3) |

We mock only the FS for glob unit tests and clock for tz tests.
EXIF write tests use real fixture bytes (no mocking the SUT).

## 8. Logo

`assets/logo.svg`: SVG showing a camera body with a map-pin marker
overlaid on the lens. Inline (no external deps). Used at the top of
the README.

## 9. README outline

1. Hero (logo + tagline)
2. What it does
3. Install (pip install -r requirements.txt; pip install -e .)
4. Quickstart
5. CLI reference (mirrors §3)
6. Google location-history sources: how to get Takeout / Timeline
7. Caveats (HEIC re-encoding, no RAW, threshold tuning)
8. Development (tests, lint)
9. License

## 10. Open decisions, resolved

- GPS source priority: GPX > Google. **Resolved.**
- Interpolation strategy: linear, no extrapolation. **Resolved.**
- File formats: JPEG, HEIC, PNG. **Resolved.**
- `--replace` vs `--overwrite` semantics: data-replace vs file-replace,
  orthogonal. **Resolved.**
