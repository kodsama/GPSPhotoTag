/// File-backed application preferences that survive restarts: the light/dark
/// theme choice and the defaults the Tag action starts from (RAW mode and the
/// max time-difference). Mirrors EpubToM4b's `ThemeController` pattern, widened
/// to a tiny JSON store so a few prefs live in one place.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:stunda_engine/stunda_engine.dart';

/// A small, persisted bag of user preferences.
///
/// Construct directly with explicit values (tests), or via [load] which reads
/// `preferences.json` in a given directory. [save] writes the current values
/// back (best-effort — persistence never throws into the UI).
class AppPrefs {
  /// Creates a prefs bag. [file] is the backing JSON path (null disables saving,
  /// useful in tests that only assert in-memory behaviour).
  AppPrefs({
    this.file,
    this.themeMode = ThemeMode.system,
    this.defaultRawMode = RawMode.auto,
    this.defaultMaxTimeDiffSeconds = 300,
  });

  /// The backing JSON file path, or null when persistence is disabled.
  final String? file;

  /// The persisted theme choice (light/dark; system until the user picks).
  ThemeMode themeMode;

  /// The RAW write strategy the Tag action starts from.
  RawMode defaultRawMode;

  /// The max time-difference (seconds) the Tag action starts from.
  int defaultMaxTimeDiffSeconds;

  /// Loads preferences from `preferences.json` in [dir], falling back to the
  /// defaults for anything missing or unreadable.
  static Future<AppPrefs> load(String dir) async {
    final path = p.join(dir, 'preferences.json');
    final prefs = AppPrefs(file: path);
    try {
      final raw = await File(path).readAsString();
      final map = jsonDecode(raw) as Map<String, dynamic>;
      prefs.themeMode = _parseThemeMode(map['themeMode'] as String?);
      prefs.defaultRawMode = _parseRawMode(map['defaultRawMode'] as String?);
      final secs = map['defaultMaxTimeDiffSeconds'];
      if (secs is int && secs >= 0) prefs.defaultMaxTimeDiffSeconds = secs;
    } on Object {
      // No saved preferences yet (or unreadable) — keep the defaults.
    }
    return prefs;
  }

  /// Persists the current values to [file] (best-effort; never throws).
  Future<void> save() async {
    final path = file;
    if (path == null) return;
    try {
      await File(path).writeAsString(
        jsonEncode(<String, dynamic>{
          'themeMode': themeMode.name,
          'defaultRawMode': defaultRawMode.name,
          'defaultMaxTimeDiffSeconds': defaultMaxTimeDiffSeconds,
        }),
      );
    } on Object {
      // Persisting is best-effort.
    }
  }

  static ThemeMode _parseThemeMode(String? name) => switch (name) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  static RawMode _parseRawMode(String? name) => switch (name) {
    'sidecar' => RawMode.sidecar,
    'embed' => RawMode.embed,
    _ => RawMode.auto,
  };
}
