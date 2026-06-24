# GPSPhotoTag for agents

`gpsphototag` is a headless, scriptable CLI for writing GPS EXIF into photos
from GPX tracks or Google location history, plus pruning orphan RAW files,
fixing dates, and rendering heatmaps. This document is the contract for driving
it programmatically.

## Discovery flow

1. **Read the schema.** Run `gpsphototag schema` — it prints a JSON document
   describing every command, its options, the event shapes, and the exit codes.
   Parse it; do not hard-code command knowledge.
2. **Probe the environment.** Run `gpsphototag --json check` to learn which
   external tools are present (exiftool unlocks RAW-embed + HEIC; libheif unlocks
   HEIC decode). Each entry includes an `installCommand` when missing.
3. **Pick a command and run it with `--json`.** Every run streams newline-
   delimited JSON events on stdout (see below). Branch on the exit code.

## Global flags

- `--json` — emit one JSON object per line on stdout (machine mode). Always pass
  this when driving the tool programmatically.
- `--verbose` — include `debug`-level log events.

## Event contract (`--json`)

One JSON object per line on stdout. The `event` field discriminates:

| event | fields |
|---|---|
| `log` | `level` (`debug`/`info`/`warning`/`error`), `message` |
| `progress` | `done`, `total` |
| `item` | `path`, `status`, optional `timestamp` (ISO-8601 UTC), `lat`, `lon`, `source`, `note` |
| `done` | `summary` (`{status: count}`), `total` |
| `error` | `code` (`bad_input`/`missing_toolkit`/`internal`), `message` |

`status` values: `tagged`, `interpolated`, `already_tagged`, `no_gps`,
`no_timestamp`, `dates_fixed`, `dry_run`, `pruned_trashed`, `pruned_deleted`,
`error`.

## Exit codes

| code | meaning |
|---|---|
| `0` | ok — every item succeeded |
| `2` | partial — some `no_gps` / `no_timestamp` / per-item `error` |
| `3` | bad input / arguments |
| `4` | a required external tool is missing |
| `5` | internal error |

## Examples

```bash
# Discover, then tag a folder from a GPX track, machine-readable:
gpsphototag schema
gpsphototag --json check
gpsphototag --json tag -p ~/Pictures/Trip -g trip.gpx --overwrite

# Preview only (writes nothing):
gpsphototag --json tag -p ~/Pictures/Trip -g trip.gpx --dry-run

# Remove RAW files with no JPG/HEIC companion (to Trash):
gpsphototag --json prune-raw -p ~/Pictures/Trip

# Realign file dates from EXIF:
gpsphototag --json fix-dates -p ~/Pictures/Trip --mode exif
```

Parse `done.summary` for the final tally; treat exit `2` as "completed, review
the `no_gps`/`error` items", not as failure. Never rely on the human-readable
output — it is not stable; the `--json` stream is.
