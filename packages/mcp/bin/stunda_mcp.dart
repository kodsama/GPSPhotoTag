import 'dart:async';
import 'dart:io';

import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda_mcp/stunda_mcp.dart';

/// Entry point for the Stunda MCP server.
///
/// Default transport is **stdio** (an MCP client spawns this binary). Pass
/// `--tcp [--port N]` to instead serve on a localhost TCP socket (default
/// 8787). In stdio mode nothing but JSON-RPC is ever written to stdout — all
/// diagnostics go to stderr.
Future<void> main(List<String> args) async {
  const runner = SystemProcessRunner();
  final exiftool = await _detectExiftool(runner);
  final server = McpServer(
    tools: buildTools(runner: runner, exiftoolAvailable: exiftool),
  );

  if (args.contains('--tcp')) {
    final port = _intAfter(args, '--port') ?? 8787;
    await serveTcp(server, port: port, onLog: stderr.writeln);
    stderr.writeln('stunda MCP server ready (tcp). Ctrl-C to stop.');
    await Completer<void>().future; // run until killed
  } else {
    await serveStdio(server);
  }
}

Future<bool> _detectExiftool(ProcessRunner runner) async {
  final tools = await ToolkitChecker(runner).check();
  return tools.any((t) => t.id == 'exiftool' && t.present);
}

int? _intAfter(List<String> args, String flag) {
  final i = args.indexOf(flag);
  if (i < 0 || i + 1 >= args.length) return null;
  return int.tryParse(args[i + 1]);
}
