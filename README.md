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

It also: renders a **density heatmap** of where photos were taken, **prunes**
RAW files that have no JPG/HEIC companion, and **fixes dates** between EXIF and
the filesystem.

Two front-ends, one engine:

- **Desktop app** (macOS / Linux / Windows) — a guided, stepped walkthrough.
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

A stepped, collapsible walkthrough — one step open at a time, auto-advancing,
completed steps collapse with a check and stay tappable:

1. **Toolkit** — checks exiftool / libheif / your package manager, with Install
   buttons; never claims "ready" when it isn't.
2. **Photos** — native folder picker, plus an **Add folder** affordance and
   **drag-and-drop**: combine several folders and/or individual photos and GPS
   files into one library, then review the parsed summary over the whole set.
3. **Review** — per-format include/exclude checklist.
4. **Options** — every option, smart defaults pre-selected.
5. **Output** — in place, or copy to a destination folder.
6. **Run** — global + per-item progress; errors surfaced in the UI.
7. **Result** — summary, plus one-click **heatmap**, **prune RAW**, **fix dates**.

A floating activity-log button (bottom-right) opens a panel with the full event
log. Heavy work runs in **worker isolates**, so the UI stays responsive.

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
  `packages/mcp/bin/stunda_mcp.dart`), **and** the desktop app keeps an **always-on TCP** endpoint at
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

## Development

```bash
flutter pub get                       # resolves the whole workspace
dart analyze packages                 # engine + cli
dart test packages/engine packages/cli
cd app && flutter analyze && flutter test
```

## License

Copyright © 2026 Kodsama (Alexandre Martins). Stunda is free software under
the **GNU General Public License v3.0 or later (GPL-3.0-or-later)** — see
[LICENSE](LICENSE). It comes with no warranty, to the extent permitted by law.
