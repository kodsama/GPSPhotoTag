# Stunda for agents

> **Two ways to drive this tool as an LLM:**
> 1. **MCP server** (recommended) - a standard Model Context Protocol server, see
>    [MCP](#mcp-model-context-protocol) below. Best for any MCP client.
> 2. **CLI JSON contract** - `--json` + `schema`, documented in the rest of this
>    file. Best for shell scripts and ad-hoc automation.



`stunda` is a headless, scriptable CLI for writing GPS EXIF into photos
from GPX tracks or Google location history, plus pruning orphan RAW files,
fixing dates, and rendering heatmaps. This document is the contract for driving
it programmatically.

## Discovery flow

1. **Read the schema.** Run `stunda schema` - it prints a JSON document
   describing every command, its options, the event shapes, and the exit codes.
   Parse it; do not hard-code command knowledge.
2. **Probe the environment.** Run `stunda --json check` to learn which
   external tools are present (exiftool unlocks RAW-embed + HEIC; libheif unlocks
   HEIC decode). Each entry includes an `installCommand` when missing.
3. **Pick a command and run it with `--json`.** Every run streams newline-
   delimited JSON events on stdout (see below). Branch on the exit code.

## Global flags

- `--json` - emit one JSON object per line on stdout (machine mode). Always pass
  this when driving the tool programmatically.
- `--verbose` - include `debug`-level log events.

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
| `0` | ok - every item succeeded |
| `2` | partial - some `no_gps` / `no_timestamp` / per-item `error` |
| `3` | bad input / arguments |
| `4` | a required external tool is missing |
| `5` | internal error |

## Examples

```bash
# Discover, then tag a folder from a GPX track, machine-readable:
stunda schema
stunda --json check
stunda --json tag -p ~/Pictures/Trip -g trip.gpx --overwrite

# Preview only (writes nothing):
stunda --json tag -p ~/Pictures/Trip -g trip.gpx --dry-run

# Remove RAW files with no JPG/HEIC companion (to Trash):
stunda --json prune-raw -p ~/Pictures/Trip

# Realign file dates from EXIF:
stunda --json fix-dates -p ~/Pictures/Trip --mode exif
```

Parse `done.summary` for the final tally; treat exit `2` as "completed, review
the `no_gps`/`error` items", not as failure. Never rely on the human-readable
output - it is not stable; the `--json` stream is.

## MCP (Model Context Protocol)

Stunda ships a standard MCP server (JSON-RPC 2.0) exposing the engine as
tools. It speaks the usual lifecycle: `initialize` → `notifications/initialized`
→ `tools/list` → `tools/call`.

**Tools:** `tag_photos`, `render_heatmap`, `prune_raw`, `fix_dates`,
`check_toolkit`, `get_capabilities`. Each `tools/call` returns a `content` text
block **and** a `structuredContent` object: `{ ok, summary, count, items[], logs[] }`
(or `{ ok:false, code, error }`). `isError` is set when a call fails.

**Two transports, same tools:**

- **stdio** (recommended for clients that spawn a subprocess) - run the compiled
  binary `stunda_mcp` (build it with
  `dart compile exe packages/mcp/bin/stunda_mcp.dart -o stunda_mcp`).
- **TCP** - the desktop app starts the server on `127.0.0.1:8787` (next free
  port up to 8796) **whenever the app is open**; newline-delimited JSON-RPC. Run
  the binary the same way with `--tcp [--port N]`. Read the bound port from the
  header's MCP button (or Settings) rather than assuming 8787 - when another
  program holds it the server moves, and connecting to 8787 anyway reaches that
  other program, whose refusal has nothing to do with Stunda. There is no
  authentication on either transport; `initialize` is the whole handshake, and
  its `serverInfo` names the app and version so a client can confirm what it
  reached.

**Client config (stdio):**

```json
{
  "mcpServers": {
    "stunda": { "command": "/absolute/path/to/stunda_mcp" }
  }
}
```

A copy lives at [`docs/mcp-client-config.json`](docs/mcp-client-config.json).

**Minimal session:**

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"tag_photos","arguments":{"photos":["~/Pictures/Trip"],"gpx":["~/Pictures/Trip"],"overwrite":true,"dry_run":true}}}
```
