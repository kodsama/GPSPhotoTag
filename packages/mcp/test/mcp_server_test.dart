import 'package:gpsphototag_engine/gpsphototag_engine.dart';
import 'package:gpsphototag_mcp/gpsphototag_mcp.dart';
import 'package:test/test.dart';

/// Returns canned results so tools that probe exiftool don't shell out.
class _FakeRunner implements ProcessRunner {
  @override
  Future<ProcResult> run(String executable, List<String> args) async {
    if (executable == 'exiftool') return const ProcResult(0, '13.55', '');
    return const ProcResult(0, '', '');
  }
}

McpServer _server() => McpServer(
  tools: buildTools(runner: _FakeRunner(), exiftoolAvailable: true),
);

Map<String, Object?> _req(
  int id,
  String method, [
  Map<String, Object?>? params,
]) {
  final m = <String, Object?>{'jsonrpc': '2.0', 'id': id, 'method': method};
  if (params != null) m['params'] = params;
  return m;
}

void main() {
  test('initialize echoes protocol version and advertises tools', () async {
    final r = await _server().handle(
      _req(1, 'initialize', {
        'protocolVersion': '2025-06-18',
        'capabilities': <String, Object?>{},
      }),
    );
    final result = r!['result'] as Map<String, Object?>;
    expect(result['protocolVersion'], '2025-06-18');
    expect(
      (result['capabilities'] as Map<String, Object?>).containsKey('tools'),
      isTrue,
    );
    expect(
      (result['serverInfo'] as Map<String, Object?>)['name'],
      'gpsphototag',
    );
  });

  test('notifications (no id) get no response', () async {
    final r = await _server().handle({
      'jsonrpc': '2.0',
      'method': 'notifications/initialized',
    });
    expect(r, isNull);
  });

  test('tools/list returns the catalog with input schemas', () async {
    final r = await _server().handle(_req(2, 'tools/list'));
    final tools =
        (r!['result'] as Map<String, Object?>)['tools'] as List<Object?>;
    final names = tools.map((t) => (t as Map<String, Object?>)['name']).toSet();
    expect(
      names,
      containsAll(<String>{
        'tag_photos',
        'render_heatmap',
        'prune_raw',
        'fix_dates',
        'check_toolkit',
        'get_capabilities',
      }),
    );
    for (final t in tools) {
      expect(
        (t as Map<String, Object?>)['inputSchema'],
        isA<Map<String, Object?>>(),
      );
    }
  });

  test(
    'tools/call check_toolkit returns content + structuredContent',
    () async {
      final r = await _server().handle(
        _req(3, 'tools/call', {'name': 'check_toolkit', 'arguments': {}}),
      );
      final result = r!['result'] as Map<String, Object?>;
      expect(result['isError'], isFalse);
      expect(result['content'], isA<List<Object?>>());
      final structured = result['structuredContent'] as Map<String, Object?>;
      expect(structured['ok'], isTrue);
      expect(structured['tools'], isA<List<Object?>>());
    },
  );

  test('tools/call validates arguments (no photos -> tool error)', () async {
    final r = await _server().handle(
      _req(4, 'tools/call', {
        'name': 'tag_photos',
        'arguments': {'photos': <String>[]},
      }),
    );
    final result = r!['result'] as Map<String, Object?>;
    expect(result['isError'], isTrue);
    expect(
      (result['structuredContent'] as Map<String, Object?>)['code'],
      'bad_input',
    );
  });

  test('unknown tool -> invalid params error', () async {
    final r = await _server().handle(
      _req(5, 'tools/call', {'name': 'nope', 'arguments': {}}),
    );
    expect((r!['error'] as Map<String, Object?>)['code'], -32602);
  });

  test('unknown method -> method not found', () async {
    final r = await _server().handle(_req(6, 'frobnicate'));
    expect((r!['error'] as Map<String, Object?>)['code'], -32601);
  });

  test(
    'a thrown tool is reported as a tool error, not a protocol error',
    () async {
      final server = McpServer(
        tools: [
          McpTool(
            name: 'boom',
            description: 'always throws',
            inputSchema: const {'type': 'object', 'properties': {}},
            run: (_) async => throw StateError('kaboom'),
          ),
        ],
      );

      final r = await server.handle(
        _req(8, 'tools/call', {'name': 'boom', 'arguments': {}}),
      );

      // It's a JSON-RPC result (not an error), but flagged isError with the text.
      final result = r!['result'] as Map<String, Object?>;
      expect(result['isError'], isTrue);
      final content =
          (result['content'] as List<Object?>).single as Map<String, Object?>;
      expect(content['text'], contains('boom'));
      expect(content['text'], contains('kaboom'));
    },
  );

  test('get_capabilities reflects exiftool availability', () async {
    final off = McpServer(
      tools: buildTools(runner: _FakeRunner(), exiftoolAvailable: false),
    );
    final r = await off.handle(
      _req(7, 'tools/call', {'name': 'get_capabilities', 'arguments': {}}),
    );
    final structured =
        ((r!['result'] as Map<String, Object?>)['structuredContent'])
            as Map<String, Object?>;
    expect(structured['exiftool_available'], isFalse);
    expect(
      (structured['formats'] as Map<String, Object?>)['heic'],
      contains('exiftool'),
    );
  });
}
