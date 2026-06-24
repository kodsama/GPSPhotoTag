import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'mcp_server.dart';

/// Serves [server] over stdio: newline-delimited JSON-RPC on stdin/stdout.
///
/// This is the transport an MCP client uses when it spawns the server as a
/// subprocess. Completes when stdin closes.
Future<void> serveStdio(McpServer server) async {
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final response = await _process(server, line);
    if (response != null) {
      stdout.writeln(jsonEncode(response));
      await stdout.flush();
    }
  }
}

/// Serves [server] over a localhost TCP socket, one newline-delimited JSON-RPC
/// message per line. Returns the bound [ServerSocket] so the caller can close
/// it; [onLog] receives lifecycle lines (bind, connect, disconnect).
///
/// Used by the desktop app to keep an "always-on" endpoint while it runs.
Future<ServerSocket> serveTcp(
  McpServer server, {
  String host = '127.0.0.1',
  int port = 8787,
  void Function(String message)? onLog,
}) async {
  final socket = await ServerSocket.bind(host, port);
  onLog?.call('MCP server listening on $host:${socket.port}');
  socket.listen((client) {
    onLog?.call('client connected: ${client.remoteAddress.address}');
    const splitter = LineSplitter();
    var buffer = '';
    utf8.decoder.bind(client).listen(
      (chunk) async {
        buffer += chunk;
        // Process every complete line; keep the trailing partial in the buffer.
        final parts = buffer.split('\n');
        buffer = parts.removeLast();
        for (final raw in parts) {
          for (final line in splitter.convert(raw)) {
            if (line.trim().isEmpty) continue;
            final response = await _process(server, line);
            if (response != null) client.writeln(jsonEncode(response));
          }
        }
      },
      onDone: () => onLog?.call('client disconnected'),
      onError: (Object _) => client.destroy(),
      cancelOnError: true,
    );
  });
  return socket;
}

/// Decodes one line, dispatches it, and returns the response map (or null for a
/// notification). Malformed JSON yields a JSON-RPC parse error.
Future<Map<String, Object?>?> _process(McpServer server, String line) async {
  final Object? decoded;
  try {
    decoded = jsonDecode(line);
  } on FormatException {
    return {
      'jsonrpc': '2.0',
      'id': null,
      'error': {'code': -32700, 'message': 'Parse error'},
    };
  }
  if (decoded is! Map) {
    return {
      'jsonrpc': '2.0',
      'id': null,
      'error': {'code': -32600, 'message': 'Invalid Request'},
    };
  }
  return server.handle(decoded.cast<String, Object?>());
}
