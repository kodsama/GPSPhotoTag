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
    this.backgroundImagePath,
    this.backgroundVeil = 0.85,
    this.keepPipeline = KeepPipeline.standard,
    this.localeCode,
    Set<QualityParam>? lowQParams,
    this.lowQThreshold = 0.35,
    this.similarityPercent = 0,
  }) : lowQParams = lowQParams ?? QualityParam.values.toSet();

  /// The backing JSON file path, or null when persistence is disabled.
  final String? file;

  /// The persisted theme choice (light/dark; system until the user picks).
  ThemeMode themeMode;

  /// The RAW write strategy the Tag action starts from.
  RawMode defaultRawMode;

  /// The max time-difference (seconds) the Tag action starts from.
  int defaultMaxTimeDiffSeconds;

  /// Path to a user-chosen background image, or null to use the default
  /// map-style background.
  String? backgroundImagePath;

  /// Opacity (0.0–1.0) of the readability veil drawn over the background; higher
  /// is more subtle (more veil, fainter background). Defaults to a subtle 0.85.
  double backgroundVeil;

  /// The duplicate-finder keep-priority pipeline (rule order + enabled flags).
  KeepPipeline keepPipeline;

  /// The user's language override (a supported locale code), or null to follow
  /// the system locale.
  String? localeCode;

  /// The quality components the Shrink "low quality" stage treats as defining
  /// low quality (default: all four). The candidate filter scores each photo on
  /// only these via [compositeFrom].
  Set<QualityParam> lowQParams;

  /// The Shrink "low quality" stage's quality threshold in 0..1 (default 0.35).
  double lowQThreshold;

  /// The duplicate-finder looseness slider, a percent 0..100 (default 0 = Exact).
  /// Snapped to a multiple of 10 by the controller on use.
  int similarityPercent;

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
      final bg = map['backgroundImagePath'];
      if (bg is String && bg.isNotEmpty) prefs.backgroundImagePath = bg;
      final veil = map['backgroundVeil'];
      if (veil is num) prefs.backgroundVeil = veil.toDouble().clamp(0.0, 1.0);
      if (map.containsKey('keepPipeline')) {
        prefs.keepPipeline = KeepPipeline.fromJson(map['keepPipeline']);
      }
      final code = map['localeCode'];
      if (code is String && code.isNotEmpty) prefs.localeCode = code;
      final params = map['lowQParams'];
      if (params is List) prefs.lowQParams = _parseLowQParams(params);
      final lowQT = map['lowQThreshold'];
      if (lowQT is num) prefs.lowQThreshold = lowQT.toDouble().clamp(0.0, 1.0);
      // Clamp any persisted value into the new 0..100 looseness range; an old
      // 0..15-step value lands at the strict end and is snapped on use.
      final sim = map['similarityPercent'];
      if (sim is int) prefs.similarityPercent = sim.clamp(0, 100);
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
          'backgroundImagePath': backgroundImagePath,
          'backgroundVeil': backgroundVeil,
          'keepPipeline': keepPipeline.toJson(),
          'localeCode': localeCode,
          'lowQParams': [for (final p in lowQParams) p.name],
          'lowQThreshold': lowQThreshold,
          'similarityPercent': similarityPercent,
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

  /// Parses a persisted list of [QualityParam] names, ignoring any unknown
  /// entries. An empty/all-unknown list is honoured as the empty set (the user
  /// had every toggle off).
  static Set<QualityParam> _parseLowQParams(List<dynamic> raw) {
    final byName = {for (final p in QualityParam.values) p.name: p};
    return {
      for (final entry in raw)
        if (entry is String && byName.containsKey(entry)) byName[entry]!,
    };
  }
}
