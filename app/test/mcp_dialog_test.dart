import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stunda/main.dart';
import 'package:stunda/src/engine/mcp_service.dart';
import 'package:stunda/src/state/app_controller.dart';
import 'package:stunda/src/widgets/mcp_dialog.dart';

import 'support/fakes.dart';

void main() {
  test('the config names the live port, the version, and no auth', () {
    // The port is the whole point of copying this: it moves when something
    // else holds 8787, which is exactly how a client ended up talking to a
    // different app entirely.
    final config = jsonDecode(
      mcpConnectionConfig(port: 8791, version: '9.9.9'),
    ) as Map<String, Object?>;

    expect(config['port'], 8791);
    expect(config['host'], '127.0.0.1');
    expect(config['auth'], 'none');
    expect((config['server'] as Map)['title'], 'Stunda');
    expect((config['server'] as Map)['version'], '9.9.9');
    // No key anywhere: a snippet with a credential field invites someone to go
    // hunting for a key this server never asks for.
    expect(mcpConnectionConfig(port: 1, version: '1'), isNot(contains('Key')));
    expect(mcpConnectionConfig(port: 1, version: '1'), isNot(contains('key')));
  });

  testWidgets('the header carries an MCP button that opens the panel', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      StundaApp(controller: AppController(runner: FakeEngineRunner())),
    );
    await tester.pump();

    // An injected controller never starts the server, so the dot is the
    // starting colour and the panel opens against a port-less service.
    await tester.tap(find.byIcon(Icons.hub_outlined));
    await tester.pumpAndSettle();

    expect(find.byType(McpDialog), findsOneWidget);
    expect(find.text('Transport'), findsOneWidget);
    expect(find.text('None, loopback only'), findsOneWidget);
  });

  testWidgets('with no server the copy button is disabled and says why', (
    tester,
  ) async {
    final service = McpService();
    addTearDown(service.dispose);

    await tester.pumpWidget(MaterialApp(home: McpDialog(mcp: service)));
    await tester.pump();

    expect(find.textContaining('8787-8796'), findsOneWidget);
    final copy = tester.widget<TextButton>(
      find.ancestor(
        of: find.text('Copy config'),
        matching: find.byType(TextButton),
      ),
    );
    expect(copy.onPressed, isNull, reason: 'nothing to copy without a port');
  });

  testWidgets('a running server is copied as a reachable address', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final service = McpService(appVersion: '9.9.9');
    addTearDown(service.dispose);
    await tester.runAsync(() async {
      await service.start(base: 19400);
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!service.running && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    expect(service.running, isTrue, reason: 'server never bound');

    // A Scaffold below the messenger, as AppShell provides in the real app:
    // the copy confirmation is a SnackBar.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: McpDialog(mcp: service)),
      ),
    );
    await tester.pump();
    expect(find.text('127.0.0.1:${service.port}'), findsOneWidget);
    expect(find.text('Stunda 9.9.9'), findsOneWidget);

    await tester.tap(find.text('Copy config'));
    await tester.pump();

    final copied = calls.firstWhere((c) => c.method == 'Clipboard.setData');
    final payload = jsonDecode(
      (copied.arguments as Map)['text'] as String,
    ) as Map<String, Object?>;
    expect(payload['port'], service.port);
    expect((payload['server'] as Map)['version'], '9.9.9');
  });
}
