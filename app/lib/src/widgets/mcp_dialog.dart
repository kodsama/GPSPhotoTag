/// The MCP connection panel: which app is answering, where it listens, and a
/// copyable config for a local LLM that wants to reach it.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine/mcp_service.dart';
import '../i18n/app_localizations.dart';
import 'settings_dialog.dart' show mcpStatus;

/// Everything a local MCP client needs to reach this app, as pasteable JSON.
///
/// TCP is the only transport a running app offers - the stdio binary is built
/// from the repo and is not inside the bundle - so this describes the live
/// socket rather than a command to spawn. The port is included because it
/// moves: the app walks 8787..8796 to step over whatever already holds one.
String mcpConnectionConfig({required int port, required String version}) =>
    const JsonEncoder.withIndent('  ').convert({
      'server': {'name': 'stunda', 'title': 'Stunda', 'version': version},
      'transport': 'tcp',
      'host': '127.0.0.1',
      'port': port,
      'framing': 'newline-delimited JSON-RPC 2.0, one message per line',
      'auth': 'none',
      'initialize': {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2025-06-18',
          'capabilities': <String, Object?>{},
          'clientInfo': {'name': 'local-llm', 'version': '1'},
        },
      },
    });

/// Opens the MCP panel for [mcp].
void showMcpDialog(BuildContext context, McpService mcp) {
  showDialog<void>(
    context: context,
    builder: (_) => McpDialog(mcp: mcp),
  );
}

/// The MCP panel. Rebuilds with the service so the status cannot go stale while
/// it is open.
class McpDialog extends StatelessWidget {
  /// Creates the panel bound to [mcp].
  const McpDialog({super.key, required this.mcp});

  /// The server whose state is shown.
  final McpService mcp;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: mcp,
      builder: (context, _) {
        final status = mcpStatus(
          context.tr,
          running: mcp.running,
          port: mcp.port,
          error: mcp.error,
        );
        final port = mcp.port;
        final version = mcp.appVersion ?? kEnglishStrings['app_version']!;
        return AlertDialog(
          title: Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: status.color,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Text(context.tr('settings_mcp_server')),
              const SizedBox(width: 10),
              Text(status.label, style: text.bodySmall),
            ],
          ),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _row(context, 'mcp_app', 'Stunda $version'),
                _row(
                  context,
                  'mcp_address',
                  port == null
                      ? context.tr('settings_mcp_off')
                      : '127.0.0.1:$port',
                ),
                _row(
                  context,
                  'mcp_transport',
                  context.tr('mcp_transport_value'),
                ),
                _row(context, 'mcp_auth', context.tr('mcp_auth_none')),
                if (port == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      context.tr('mcp_offline_hint'),
                      style: text.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: mcp.restart,
              icon: const Icon(Icons.refresh),
              label: Text(context.tr('mcp_restart')),
            ),
            TextButton.icon(
              onPressed: port == null
                  ? null
                  : () => _copy(context, port, version),
              icon: const Icon(Icons.content_copy),
              label: Text(context.tr('mcp_copy_config')),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(context.tr('mcp_close')),
            ),
          ],
        );
      },
    );
  }

  Future<void> _copy(BuildContext context, int port, String version) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final copied = context.tr('mcp_config_copied');
    await Clipboard.setData(
      ClipboardData(
        text: mcpConnectionConfig(port: port, version: version),
      ),
    );
    messenger?.showSnackBar(SnackBar(content: Text(copied)));
  }

  Widget _row(BuildContext context, String labelKey, String value) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(context.tr(labelKey), style: text.bodySmall),
          ),
          Expanded(child: Text(value, style: text.bodyMedium)),
        ],
      ),
    );
  }
}
