import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:stunda_engine/stunda_engine.dart';

import '../exit_codes.dart';

/// `scan` — walk a library and report what it holds, changing nothing.
///
/// The headless form of the GUI's Review summary: photo/track/history counts,
/// the per-extension breakdown, and the unsupported buckets. Read-only.
class ScanCommand extends Command<int> {
  /// Creates the command. [sink] overrides stdout (for tests). [scanner]
  /// overrides the walker so tests can drive it without a real tree.
  ScanCommand({IOSink? sink, FolderScanner? scanner})
    : _out = sink ?? stdout,
      _scanner = scanner ?? FolderScanner() {
    argParser
      ..addMultiOption(
        'photo',
        abbr: 'p',
        help: 'Root file or directory to scan (repeatable).',
      )
      ..addFlag(
        'paths',
        negatable: false,
        help: 'Include the full photo/track/history path lists.',
      );
  }

  final IOSink _out;
  final FolderScanner _scanner;

  @override
  String get name => 'scan';

  @override
  String get description =>
      'Scan a library and report its contents (read-only).';

  @override
  Future<int> run() async {
    final roots = argResults!.multiOption('photo');
    final json = globalResults!.flag('json');
    if (roots.isEmpty) {
      _out.writeln(
        json
            ? jsonEncode({
                'event': 'error',
                'code': 'bad_input',
                'message': 'no roots given for --photo',
              })
            : 'error: no roots given for --photo',
      );
      return ExitCodes.badInput;
    }

    FolderScanResult? result;
    await for (final e in _scanner.scan(roots)) {
      switch (e) {
        case ScanDoneEvent(result: final r):
          result = r;
        case ScanLogEvent(:final message):
          if (json) {
            _out.writeln(
              jsonEncode({
                'event': 'log',
                'level': 'warning',
                'message': message,
              }),
            );
          }
        case ScanProgressEvent():
          break;
      }
    }
    if (result == null) return ExitCodes.internal;

    final payload = <String, Object?>{
      if (json) 'event': 'scan',
      ...result.toJson(),
    };
    if (!argResults!.flag('paths')) {
      payload
        ..remove('photos')
        ..remove('gpxFiles')
        ..remove('kmlFiles')
        ..remove('googleFiles')
        ..remove('unsupported');
    }
    _out.writeln(
      json
          ? jsonEncode(payload)
          : const JsonEncoder.withIndent('  ').convert(payload),
    );
    return ExitCodes.ok;
  }
}
