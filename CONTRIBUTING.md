# Contributing to GPSPhotoTag

GPSPhotoTag is a Dart pub **workspace**: a Flutter-free engine, a CLI, an MCP
server, and a Flutter desktop/mobile GUI all resolve together from one root
lockfile.

| Package           | Path               | What it is                         |
| ----------------- | ------------------ | ---------------------------------- |
| `gpsphototag_engine` | `packages/engine` | Pure-Dart engine library           |
| `gpsphototag_cli`    | `packages/cli`    | CLI binary `gpsphototag`           |
| `gpsphototag_mcp`    | `packages/mcp`    | MCP server binary `gpsphototag_mcp`|
| `gpsphototag_gui`    | `app`             | Flutter desktop + mobile app       |

Toolchain: **Flutter 3.44.3 / Dart 3.12.2** (pinned in CI).

## One-time setup

```bash
flutter pub get          # resolves the whole workspace
bash tool/setup-hooks.sh # installs the pre-commit hook
```

`tool/setup-hooks.sh` runs `git config core.hooksPath .githooks` and makes the
hooks executable. After this, every `git commit` runs the same gate as CI.

## The pre-commit gate (mirrors CI)

`.githooks/pre-commit` fast-fails the commit on any of:

1. `dart format --output=none --set-exit-if-changed .`
2. `dart analyze` (covers the engine, cli, mcp packages at the workspace root)
3. `(cd app && flutter analyze)`
4. `dart test packages/engine packages/cli packages/mcp` and `(cd app && flutter test)`

Run it manually any time:

```bash
bash .githooks/pre-commit
```

If the format step fails, apply the formatter and re-commit:

```bash
dart format .
```

## Lint & test commands

```bash
# Format (write) / format (check)
dart format .
dart format --output=none --set-exit-if-changed .

# Static analysis
dart analyze
(cd app && flutter analyze)

# Tests
dart test packages/engine packages/cli packages/mcp
(cd app && flutter test)
```

## Coverage gate (≥90% line coverage per package)

CI enforces **≥90% line coverage for every package** with
`tool/check_coverage.sh <lcov-file> <minPercent>`. Reproduce locally:

```bash
dart pub global activate coverage

# Dart packages: collect + convert to lcov, then check.
( cd packages/engine && dart test --coverage=coverage && \
  dart pub global run coverage:format_coverage --lcov --check-ignore \
    --in=coverage --out=coverage/lcov.info --report-on=lib )
bash tool/check_coverage.sh packages/engine/coverage/lcov.info 90

# Flutter app:
( cd app && flutter test --coverage )
bash tool/check_coverage.sh app/coverage/lcov.info 90
```

Repeat the Dart steps for `packages/cli` and `packages/mcp`.

## CI

`.github/workflows/ci.yml` runs on every push to `main` and every pull request:
format check → analyze (Dart + Flutter) → tests with coverage → per-package
90% coverage gate → upload lcov artifacts.

## Releases

See [`docs/RELEASE.md`](docs/RELEASE.md). Tag `vX.Y.Z` on `main` to build and
publish all platform artifacts.
