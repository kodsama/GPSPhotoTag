import 'dart:convert';

import 'tools.dart';

/// A minimal, dependency-free implementation of the Model Context Protocol
/// (JSON-RPC 2.0) sufficient for tool serving: `initialize`, `tools/list`,
/// `tools/call`, `ping`, and the `initialized` notification.
///
/// The server is transport-agnostic: [handle] takes one decoded JSON-RPC
/// message and returns the response map (or null for notifications). A stdio or
/// TCP transport wraps it.
/// Version advertised when no host app supplies its own.
const kMcpDefaultVersion = '2.1.1';

class McpServer {
  /// Creates a server exposing [tools].
  McpServer({
    required this.tools,
    this.name = 'stunda',
    this.title = 'Stunda',
    this.version = kMcpDefaultVersion,
    this.protocolVersion = '2025-06-18',
  });

  /// The tool catalog.
  final List<McpTool> tools;

  /// Advertised server name.
  final String name;

  /// Human-readable app name. Several local apps can serve MCP on neighbouring
  /// ports, so a client needs to see which one it actually reached.
  final String title;

  /// Advertised server version.
  final String version;

  /// Protocol revision used when the client doesn't request one.
  final String protocolVersion;

  /// Handles one decoded JSON-RPC request. Returns the response map, or null
  /// when the message is a notification (no `id`) needing no reply.
  Future<Map<String, Object?>?> handle(Map<String, Object?> request) async {
    final id = request['id'];
    final method = request['method'];
    final params =
        (request['params'] as Map?)?.cast<String, Object?>() ?? const {};

    // Notifications carry no id and never get a response.
    if (id == null) return null;

    switch (method) {
      case 'initialize':
        return _ok(id, {
          'protocolVersion':
              (params['protocolVersion'] as String?) ?? protocolVersion,
          'capabilities': {
            'tools': {'listChanged': false},
          },
          'serverInfo': {'name': name, 'title': title, 'version': version},
        });

      case 'ping':
        return _ok(id, const {});

      case 'tools/list':
        return _ok(id, {
          'tools': [
            for (final t in tools)
              {
                'name': t.name,
                'description': t.description,
                'inputSchema': t.inputSchema,
              },
          ],
        });

      case 'tools/call':
        return _call(id, params);

      default:
        return _err(id, -32601, 'Method not found: $method');
    }
  }

  Future<Map<String, Object?>> _call(
    Object id,
    Map<String, Object?> params,
  ) async {
    final toolName = params['name'] as String?;
    final args =
        (params['arguments'] as Map?)?.cast<String, Object?>() ?? const {};
    final tool = tools.where((t) => t.name == toolName).firstOrNull;
    if (tool == null) {
      return _err(id, -32602, 'Unknown tool: $toolName');
    }
    try {
      final result = await tool.run(args);
      final isError = result['ok'] == false;
      return _ok(id, {
        'content': [
          {
            'type': 'text',
            'text': const JsonEncoder.withIndent('  ').convert(result),
          },
        ],
        'structuredContent': result,
        'isError': isError,
      });
    } on Object catch (e) {
      // A thrown tool is reported as a tool error (not a protocol error) so the
      // model sees it and can recover.
      return _ok(id, {
        'content': [
          {'type': 'text', 'text': 'tool "$toolName" failed: $e'},
        ],
        'isError': true,
      });
    }
  }

  Map<String, Object?> _ok(Object id, Map<String, Object?> result) => {
    'jsonrpc': '2.0',
    'id': id,
    'result': result,
  };

  Map<String, Object?> _err(Object id, int code, String message) => {
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message},
  };
}
