<p align="center">
  <img src="app/assets/icon_1024.png" alt="Stunda" width="140"/>
</p>

<h1 align="center">Stunda</h1>

<p align="center">
  <b>Give every photo its moment.</b>
</p>

<p align="center">
  <i>A cross-platform desktop photo toolkit — tag with GPS, map your trips,
  prune orphan RAWs — plus a headless, LLM-friendly CLI, all powered by one
  pure-Dart engine.</i>
</p>

---

## The name

**Stunda** comes from the Swedish **stund** — *a moment, a little while*.

Your photos are **stunder**: thousands of small moments dropped into folders and forgotten. Stunda is where each one gets its moment again — placed on the map, tied to its track and timeline, de-duplicated, tidied, and kept.

> Why *Stunda* and not just *stund*? Because `stund` is already a STUN-server daemon, and we'd rather sort your photos than your network packets. Besides — point it at a shambolic library and it'll have the whole thing tagged, mapped, and tidy in a *stund*. ⏱️

## What it does

You take photos. Sometimes you also have a GPX track (watch, phone, handheld
GPS); when you don't, your Google location history covers you. Stunda writes
accurate GPS EXIF into your photos by matching each photo's capture time against
the first source that has a fix — GPX first (most precise), then Google.

From there it helps you **see** and **tidy** the whole library: explore your
geotagged photos on an interactive map, find visually-similar duplicates, match
images to their RAWs, compare any two shots side by side, and run a guided
"shrink" wizard that reclaims space. Everything is **review-first** — nothing is
changed or deleted until you confirm, and deletions go to the Trash.

Two front-ends, one engine:

- **Desktop app** (macOS / Linux / Windows) — a guided GUI, localized into
  **9 languages** (English, Français, Svenska, 中文, 日本語, Deutsch, Português,
  Español, Dansk), with an in-app **Help** section.
- **CLI** — scriptable, with a JSON event stream and a self-describing `schema`
  command for agents.

## Supported formats

| Family | Extensions | GPS write strategy |
|---|---|---|
| JPEG | `.jpg .jpeg` | inline, **lossless**, pure Dart |
| PNG | `.png` | inline (re-encode) |
| RAW | `.raf .nef .cr2 .cr3 .dng .arw .orf …` | XMP sidecar (default) or exiftool embed |
| HEIC | `.heic .heif` | via exiftool |

RAW timestamp reading for Fuji `.RAF` / Canon `.CR3`, RAW **embed**, and HEIC use
the external **exiftool** binary; HEIC decode uses **libheif**. The app's toolkit
checker detects these and offers one-click install. The pure-Dart JPEG/PNG path
always works with no external tools.

## The desktop app

Open a photo library — pick a folder, or **drag and drop** several folders
and/or individual photos and GPS files onto the window — and Stunda scans them
into one library, then shows a Review summary of what it found. From the
workspace you choose an action:

- **Tag with GPS** — write location from GPX / Google Timeline / KML; sidecar or
  embed for RAW, optional timezone, in place or copy. Existing coordinates are
  never overwritten unless you allow it; a dry run previews without writing.
- **Explore on map** — pan/zoom your geotagged photos, with clusters that open
  into pins. Switch between **Numbers / Heatmap / Both**, filter by a
  **Timeline** date range, **Fit to photos**, and **Save the view as PNG**. Map
  tiles are cached for offline and repeat viewing.
- **Match Images to RAW** — remove orphan RAWs, or orphan images (both
  directions), after reviewing the list.
- **Find duplicates** — pick a **matching method**: *Fast* (perceptual hash +
  colour, instant, best for near-identical copies) or *Smart* (an on-device AI
  embedding that understands crops, rotations and recolours). A similarity slider
  (Exact ↔ Loose) with a live example tunes whichever method is selected, plus a
  **Keep priority** pipeline (Resolution → Quality → People & animals,
  reorderable and toggleable). Review pairs, swap, or deselect; nothing is
  deleted until you confirm. Smart degrades to Fast when no model is bundled.
- **Comparison viewer** — open any image full-screen, with a vertical/horizontal
  curtain or side-by-side synced zoom, plus an info line (name, resolution,
  size, time, GPS, EXIF).
- **Shrink picture library** — a staged wizard (Duplicates → Orphans →
  RAW + photo pairs → Low quality) building one cumulative trash list, with
  selectable low-quality criteria (blurriness / histogram / colour / exposure)
  and a final review showing the space to free.

**Settings** cover language, light/dark, a custom background image with
intensity, and the live MCP server status. A **Help** entry in the settings menu
opens an in-app, localized guide to every feature. An activity-log button opens
the full event log, and heavy work runs in **worker isolates** so the UI stays
responsive.

```bash
cd app
flutter run -d macos     # or -d linux / -d windows
flutter build macos      # package the .app
```

## The CLI

```bash
# from the repo root
dart run stunda_cli --version
# or compile a standalone binary:
dart compile exe packages/cli/bin/stunda.dart -o stunda
```

Commands: `tag`, `map`, `prune-raw`, `fix-dates`, `check`, `info`,
`list-sources`, `list-providers`, `schema`.

```bash
# Tag a folder from a GPX track, in place:
stunda tag -p ~/Pictures/Trip -g trip.gpx --overwrite

# Heatmap PNG of an already-tagged trip:
stunda map -p ~/Pictures/Trip -o trip.png

# Remove RAW files with no JPG/HEIC companion (to Trash):
stunda prune-raw -p ~/Pictures/Trip

# Preview anything without writing:
stunda tag -p ~/Pictures/Trip -g trip.gpx --dry-run
```

### For agents / scripting

Two ways to drive it as an LLM:

- **MCP server** — a standard Model Context Protocol server (JSON-RPC 2.0) with
  tools `tag_photos`, `render_heatmap`, `prune_raw`, `fix_dates`,
  `check_toolkit`, `get_capabilities`. Runs over **stdio** (build
  `packages/mcp/bin/stunda_mcp.dart`), **and** the desktop app keeps an
  **always-on TCP** endpoint at
  `127.0.0.1:8787` whenever it's open.
- **CLI JSON contract** — `--json` emits one JSON event per line; `schema`
  describes every command, option, event, and exit code.

See [AGENTS.md](AGENTS.md) and [docs/mcp-client-config.json](docs/mcp-client-config.json).

```bash
stunda schema                       # discover the surface
stunda --json check                 # probe the environment
stunda --json tag -p ./Trip -g t.gpx --overwrite
```

Exit codes: `0` ok · `2` partial (some no-match) · `3` bad input · `4` missing
toolkit · `5` internal.

## Project layout

```
packages/engine/   pure-Dart, Flutter-free engine (domain → data → services → app)
packages/cli/      headless CLI over the engine
packages/mcp/      MCP server (stdio + TCP) over the engine
app/               Flutter desktop GUI over the engine (+ always-on MCP server)
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for the design.

## Duplicate detection & the people keep-rule

Duplicates are grouped with one of two **similarity metrics**, chosen at the top
of the Find-duplicates screen and persisted:

- **Fast** — a 256-bit perceptual DCT hash (pHash) blended with a coarse HSV
  colour signature. Instant, computed for every file; best for near-identical
  copies and re-saves. Pure maths, fully unit-tested.
- **Smart** — an on-device **image embedding**: a small Apache-2.0
  **MobileNetV2** (ONNX Model Zoo, ~14 MB) runs over the same decoded thumbnail
  through the bundled **ONNX Runtime** via `dart:ffi`, producing an L2-normalized
  vector per image; pairs are compared by cosine similarity mapped to 0..1. This
  is engine-wide (app worker isolates **and** headless `dart run`), and is far
  more robust to crops, rotations and recolours. When the embedding model or
  runtime isn't available, Smart **degrades to Fast** (surfaced in the UI).

When grouping near-duplicates, Stunda picks which copy to **keep** with an
ordered keep-rule cascade (resolution → quality → people). The `people` rule
favours the candidate that most looks like it contains a person or pet, in two
tiers:

- **Tier 1 (metadata)** — face regions, person names, and subject/keyword hints
  read from the file's existing metadata (no extra work).
- **Tier 2 (on-device detection)** — when metadata is silent, a small
  Apache-2.0 **SSD-MobileNet** COCO model runs over the thumbnail through a
  bundled **ONNX Runtime** via `dart:ffi`. This is engine-wide: it works in the
  desktop app's worker isolates **and** headlessly from plain `dart run`
  (CLI/MCP), with no Flutter dependency. When the model isn't bundled, the rule
  cleanly degrades to Tier-1-only.

The ONNX Runtime library and the model are vendored at build time (kept out of
git), exactly like exiftool:

```bash
bash tool/fetch-exiftool.sh           # exiftool + lib into app/assets/exiftool/
bash tool/fetch-onnx.sh               # ORT lib + SSD-MobileNet + MobileNetV2 into app/assets/onnx/
```

## Development

```bash
flutter pub get                       # resolves the whole workspace
bash tool/fetch-exiftool.sh           # vendor exiftool (bundled assets)
bash tool/fetch-onnx.sh               # vendor ONNX Runtime + detector model
dart analyze packages                 # engine + cli + mcp
dart test packages/engine packages/cli packages/mcp
cd app && flutter analyze && flutter test
```

## License

Copyright © 2026 Kodsama (Alexandre Martins). Stunda is free software under
the **GNU General Public License v3.0 or later (GPL-3.0-or-later)** — see
[LICENSE](LICENSE). It comes with no warranty, to the extent permitted by law.

Bundled at build time: **exiftool** (Artistic/GPL), **ONNX Runtime** (MIT), and
the **SSD-MobileNet v1** detector and **MobileNetV2** embedding models from the
ONNX Model Zoo (both **Apache-2.0**).
