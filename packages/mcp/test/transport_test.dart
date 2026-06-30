import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda_mcp/stunda_mcp.dart';
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

/// Collects all bytes written to an [IOSink] into [sink], so serveStdio's
/// output can be captured and decoded in-memory.
class _ByteCollector implements StreamConsumer<List<int>> {
  _ByteCollector(this.sink);

  final List<int> sink;

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      sink.addAll(chunk);
    }
  }

  @override
  Future<void> close() async {}
}

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

  group('serveStdio', () {
    test(
      'reads request frames from input and writes response frames to output',
      () async {
        // Feed two newline-delimited frames (plus a blank line that must be
        // skipped) into the loop via an in-memory byte stream.
        final input = Stream<List<int>>.fromIterable([
          utf8.encode(
            '${jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'})}\n',
          ),
          utf8.encode('\n'), // blank line -> skipped, no response
          utf8.encode(
            '${jsonEncode({
              'jsonrpc': '2.0',
              'id': 2,
              'method': 'tools/call',
              'params': {'name': 'get_capabilities', 'arguments': <String, Object?>{}},
            })}\n',
          ),
          // Notification (no id) -> no response frame emitted.
          utf8.encode(
            '${jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'})}\n',
          ),
        ]);

        final captured = <int>[];
        final output = IOSink(_ByteCollector(captured));

        await serveStdio(_server(), input: input, output: output);
        await output.close();

        final frames = utf8
            .decode(captured)
            .split('\n')
            .where((l) => l.trim().isNotEmpty)
            .map((l) => jsonDecode(l) as Map<String, Object?>)
            .toList();

        // Exactly two responses: ping and get_capabilities. The blank line and
        // the notification produce nothing.
        expect(frames, hasLength(2));

        final ping = frames.firstWhere((r) => r['id'] == 1);
        expect(ping['result'], isA<Map<String, Object?>>());

        final caps = frames.firstWhere((r) => r['id'] == 2);
        final result = caps['result'] as Map<String, Object?>;
        final structured = result['structuredContent'] as Map<String, Object?>;
        expect(structured['ok'], isTrue);
      },
    );

    test('defaults output to stdout when only input is injected', () async {
      // Empty input -> the loop exits immediately without writing anything, so
      // the default `output ?? stdout` branch runs but nothing reaches stdout.
      await serveStdio(_server(), input: const Stream<List<int>>.empty());
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

    // C-02: concurrent-chunk race — the first tool deliberately delays so a
    // second chunk arriving while the first await is suspended can corrupt the
    // shared buffer and/or reorder responses.  The fix (future-chain tail)
    // ensures both lines parse correctly and responses arrive in request-id order.
    test(
      'C-02: pipelined requests arriving as rapid chunks respond in order',
      () async {
        // Build a server with one slow tool (id=1) and one instant tool (id=2).
        final slowDone = Completer<void>();
        final slowTool = McpTool(
          name: 'slow',
          description: 'deliberate delay',
          inputSchema: {'type': 'object', 'properties': <String, Object?>{}},
          run: (_) async {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            return {'ok': true, 'tool': 'slow'};
          },
        );
        final fastTool = McpTool(
          name: 'fast',
          description: 'instant',
          inputSchema: {'type': 'object', 'properties': <String, Object?>{}},
          run: (_) async => {'ok': true, 'tool': 'fast'},
        );
        final server = McpServer(tools: [slowTool, fastTool]);

        final s = await serveTcp(server, port: 0);
        addTearDown(() => s.close());

        final socket = await Socket.connect('127.0.0.1', s.port);
        addTearDown(() => socket.destroy());

        final responses = <Map<String, Object?>>[];
        final gotTwo = Completer<void>();
        utf8.decoder.bind(socket).transform(const LineSplitter()).listen((
          line,
        ) {
          if (line.trim().isEmpty) return;
          responses.add(jsonDecode(line) as Map<String, Object?>);
          if (responses.length == 2 && !gotTwo.isCompleted) {
            gotTwo.complete();
          }
        });

        // Send both requests as TWO separate TCP chunks without awaiting between
        // them — this is the pipelining scenario.  The slow tool's 100 ms delay
        // means its async callback is suspended while the second chunk arrives.
        final req1 = jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
          'params': {'name': 'slow', 'arguments': <String, Object?>{}},
        });
        final req2 = jsonEncode({
          'jsonrpc': '2.0',
          'id': 2,
          'method': 'tools/call',
          'params': {'name': 'fast', 'arguments': <String, Object?>{}},
        });
        socket.writeln(req1); // chunk 1 — starts a slow await
        await socket.flush();
        // Yield to the event loop so the server starts processing req1 and
        // suspends at its Future.delayed before req2 arrives.
        await Future<void>.delayed(const Duration(milliseconds: 10));
        socket.writeln(req2); // chunk 2 — races with the first in buggy code
        await socket.flush();

        await gotTwo.future.timeout(const Duration(seconds: 5));
        slowDone.complete();

        // Both requests must have been parsed correctly (not corrupted).
        expect(responses, hasLength(2));
        final ids = responses.map((r) => r['id']).toList();
        // Responses MUST arrive in request order (id=1 first, then id=2).
        expect(ids[0], 1, reason: 'slow tool response must come first');
        expect(ids[1], 2, reason: 'fast tool response must come second');

        final r1 = (responses[0]['result'] as Map<String, Object?>);
        final sc1 = r1['structuredContent'] as Map<String, Object?>;
        expect(sc1['tool'], 'slow');

        final r2 = (responses[1]['result'] as Map<String, Object?>);
        final sc2 = r2['structuredContent'] as Map<String, Object?>;
        expect(sc2['tool'], 'fast');
      },
    );
  });
}
