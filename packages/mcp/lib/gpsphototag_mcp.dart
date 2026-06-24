/// MCP (Model Context Protocol) server for GPSPhotoTag.
///
/// Exposes the engine's operations as MCP tools over JSON-RPC 2.0, on either
/// stdio (client-spawned) or a localhost TCP socket (the desktop app's
/// always-on endpoint).
library;

export 'src/event_collector.dart' show collectResult, loadSources;
export 'src/mcp_server.dart';
export 'src/tools.dart';
export 'src/transport.dart';
