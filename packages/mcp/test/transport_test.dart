import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

void main() {
  group('processLine', () {
    test('dispatches a valid request and returns the response map', () async {
      final response = await processLine(
        _server(),
        jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}),
      );
      expect(response, isNotNull);
      expect(response!['id'], 1);
      expect(response['result'], isA<Map<String, Object?>>());
    });

    test('returns null for a notification (no id)', () async {
      final response = await processLine(
        _server(),
        jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
      );
      expect(response, isNull);
    });

    test('malformed JSON yields a -32700 parse error', () async {
      final response = await processLine(_server(), '{not json');
      expect((response!['error'] as Map<String, Object?>)['code'], -32700);
      expect(response['id'], isNull);
    });

    test('non-object JSON yields a -32600 invalid-request error', () async {
      final response = await processLine(_server(), '123');
      expect((response!['error'] as Map<String, Object?>)['code'], -32600);
    });
  });

  group('serveTcp', () {
    test('serves a JSON-RPC session over a real socket', () async {
      final s = await serveTcp(_server(), port: 0);
      addTearDown(() => s.close());

      final socket = await Socket.connect('127.0.0.1', s.port);
      addTearDown(() => socket.destroy());

      // Collect newline-delimited responses as they arrive.
      final responses = <Map<String, Object?>>[];
      final gotThree = Completer<void>();
      utf8.decoder.bind(socket).transform(const LineSplitter()).listen((line) {
        if (line.trim().isEmpty) return;
        responses.add(jsonDecode(line) as Map<String, Object?>);
        if (responses.length == 3 && !gotThree.isCompleted) {
          gotThree.complete();
        }
      });

      socket.writeln(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': {'protocolVersion': '2025-06-18'},
        }),
      );
      socket.writeln(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 2,
          'method': 'tools/call',
          'params': {
            'name': 'get_capabilities',
            'arguments': <String, Object?>{},
          },
        }),
      );
      // Malformed line -> parse error.
      socket.writeln('{bogus');
      await socket.flush();

      await gotThree.future.timeout(const Duration(seconds: 5));

      final init = responses.firstWhere((r) => r['id'] == 1);
      expect(
        (init['result'] as Map<String, Object?>)['protocolVersion'],
        '2025-06-18',
      );

      final call = responses.firstWhere((r) => r['id'] == 2);
      final result = call['result'] as Map<String, Object?>;
      final structured = result['structuredContent'] as Map<String, Object?>;
      expect(structured['ok'], isTrue);

      final parseErr = responses.firstWhere((r) => r['id'] == null);
      expect((parseErr['error'] as Map<String, Object?>)['code'], -32700);
    });

    test('non-object JSON over the socket yields -32600', () async {
      final s = await serveTcp(_server(), port: 0);
      addTearDown(() => s.close());

      final socket = await Socket.connect('127.0.0.1', s.port);
      addTearDown(() => socket.destroy());

      final firstLine = Completer<Map<String, Object?>>();
      utf8.decoder.bind(socket).transform(const LineSplitter()).listen((line) {
        if (line.trim().isEmpty) return;
        if (!firstLine.isCompleted) {
          firstLine.complete(jsonDecode(line) as Map<String, Object?>);
        }
      });

      socket.writeln('123');
      await socket.flush();

      final response = await firstLine.future.timeout(
        const Duration(seconds: 5),
      );
      expect((response['error'] as Map<String, Object?>)['code'], -32600);
    });

    test(
      'invalid UTF-8 on the socket triggers onError and destroys it',
      () async {
        final logs = <String>[];
        final s = await serveTcp(_server(), port: 0, onLog: logs.add);
        addTearDown(() => s.close());

        final socket = await Socket.connect('127.0.0.1', s.port);
        addTearDown(() => socket.destroy());

        // When the server destroys the client, our read stream completes (or
        // errors); either way the connection is observably gone.
        final closed = Completer<void>();
        socket.listen(
          (_) {},
          onError: (Object _) {
            if (!closed.isCompleted) closed.complete();
          },
          onDone: () {
            if (!closed.isCompleted) closed.complete();
          },
          cancelOnError: false,
        );

        // Wait for the connect log so the listener is attached, then send a byte
        // sequence that is not valid UTF-8 to fault the decoder stream.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        socket.add([0xff, 0xfe, 0xff]);
        await socket.flush();

        await closed.future.timeout(const Duration(seconds: 5));
        expect(logs.any((l) => l.contains('client connected')), isTrue);
      },
    );

    test('emits lifecycle log lines via onLog', () async {
      final logs = <String>[];
      final s = await serveTcp(_server(), port: 0, onLog: logs.add);
      addTearDown(() => s.close());

      final socket = await Socket.connect('127.0.0.1', s.port);
      // Give the listen callback a moment to fire the connect log.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      socket.destroy();

      expect(logs.any((l) => l.contains('listening')), isTrue);
      expect(logs.any((l) => l.contains('client connected')), isTrue);
    });
  });
}
