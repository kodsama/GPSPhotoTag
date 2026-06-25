# Architecture

Stunda is a Dart **pub workspace** with three packages. A single pure-Dart
engine holds all logic; the CLI and the Flutter GUI are thin adapters over it.

```
┌─────────────────────┐     ┌─────────────────────┐
│   app/ (Flutter)    │     │  packages/cli/      │
│   GUI adapter       │     │  CLI adapter        │
└──────────┬──────────┘     └──────────┬──────────┘
           │  depends on               │  depends on
           └───────────┬───────────────┘
                       ▼
        ┌──────────────────────────────────┐
        │  packages/engine/ (pure Dart)     │
        │  NEVER imports flutter / dart:ui  │
        │  domain → data → services → app   │
        └──────────────────────────────────┘
```

The engine is the single source of truth. The same `tag` / `map` / `prune-raw` /
`fix-dates` logic runs in the CLI process and inside the GUI's worker isolates —
there is no duplicated business logic.

## Engine layers

`packages/engine/lib/src/`

- **domain/** — immutable models and enums, no I/O: `TimedPoint`,
  `LocationResult`, `PhotoStatus`, `PhotoRow`, the options objects
  (`TagOptions`/`MapOptions`/`PruneOptions`), and the sealed `EngineEvent`
  hierarchy (`LogEvent`/`ProgressEvent`/`ItemEvent`/`DoneEvent`/`ErrorEvent`).
  Every event has `toJson()`, which is the wire format for the CLI's `--json`
  mode.
- **data/** — the outside world, behind injectable interfaces (the "ports"):
  - `ports/` — `ProcessRunner` (exiftool / package managers / SetFile), `Trash`,
    plus their system implementations.
  - `exif/` — the `ExifBackend` interface and its implementations: a pure-Dart
    lossless `JpegExifBackend`, `PngExifBackend`, `ExiftoolBackend` (RAW/HEIC),
    `XmpSidecarBackend` (RAW), a `BackendRegistry` that selects per format +
    raw-mode, and a `DispatchingExifBackend` that fronts the registry as one
    backend.
  - `sources/` — `parseGpx` and the Google `Records.json` / Timeline / KML
    parsers, each producing sorted `TimedPoint`s.
  - `collectors.dart`, `photo_formats.dart` — path expansion and format rules.
- **services/** — focused operations: `Locator` (GPX > Google, exact or
  interpolated, threshold-gated binary search), `Pruner`, `Dater`,
  `ToolkitChecker`, `MapService` (web-mercator tiles + density heatmap).
- **app/** — high-level orchestrators that compose services into a
  `Stream<EngineEvent>`. `TagService` is the canonical one: read time → convert
  to UTC → skip / locate / write → emit per-item events and a final summary.

## Dependency rule & seams

Dependencies point inward (`app → services → data → domain`); the engine never
depends on Flutter. Every external effect is an **injectable interface** with a
real and a fake implementation, so services are tested without touching the
filesystem, subprocesses, or the network:

- `ProcessRunner` → fakes record calls and return canned `ProcResult`s.
- `Trash` → a `FakeTrash` records would-be deletions.
- `ExifBackend` → fakes return seeded `PhotoMeta`.
- `http.Client` → the map renderer accepts one so tile fetching is faked offline.

## Concurrency

The engine is synchronous-friendly and isolate-safe (plain data, no Flutter, no
globals). The GUI's `IsolateRunner` spawns a worker isolate per operation, runs
the engine there (including file parsing and image work), and streams each
`EngineEvent` back over a `SendPort` — the UI isolate only renders. The CLI runs
the engine inline.

## CLI / LLM contract

`packages/cli/` wraps the engine with `package:args`. `CliOutput` renders the
event stream as newline-delimited JSON (`--json`) or a human table, and derives
the process exit code. The `schema` command emits a machine-readable description
of every command, option, event, and exit code; `AGENTS.md` documents the
discovery flow. See [AGENTS.md](AGENTS.md).

## GUI

`app/lib/src/` mirrors the engine's separation:

- **state/** — `AppController` (`ChangeNotifier`) holds all wizard/run state and
  exposes it via `ControllerScope` (an `InheritedNotifier`; no third-party state
  package).
- **engine/** — `IsolateRunner`, the isolate boundary.
- **theme/**, **branding/** — the cartographic theme and the vector `LogoMark`
  (mirrors `assets/logo.svg`, the app-icon source).
- **widgets/**, **steps/** — the app shell, the collapsible walkthrough, the
  activity-log panel, and one widget per walkthrough step. Each file has one
  clear purpose.

## Testing

- **Engine** — unit tests per module with fakes; a real-photo exiftool
  cross-check for the JPEG writer (skipped when exiftool is absent); an offline
  map render test.
- **CLI** — exit-code contract tests.
- **GUI** — widget tests for the shell, walkthrough, toolkit step, and log
  panel; a unit test for step-advance logic. The macOS build is exercised to
  prove the app compiles for real.

External effects are the only thing mocked; the system under test, the engine's
own data layer, and real file I/O in temp dirs are exercised directly.
