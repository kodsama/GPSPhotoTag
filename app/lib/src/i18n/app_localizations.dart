/// The JSON-asset localization system for Stunda.
///
/// Each supported locale has a flat `key → string` map in `assets/i18n/<code>.json`
/// with `{name}` placeholders for interpolation. [AppLocalizations] loads the
/// active locale's map (via [AppLocalizationsDelegate]) and looks keys up with
/// [tr], substituting `{placeholders}` and falling back to English — and then to
/// the key itself — so a missing key is visible but never crashes.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'app_strings.g.dart';

export 'app_strings.g.dart' show kEnglishStrings;

/// The locale codes Stunda ships translations for. English is the source of
/// truth and the fallback for any missing key.
const List<String> kSupportedLanguageCodes = [
  'en',
  'fr',
  'sv',
  'zh',
  'ja',
  'de',
  'pt',
  'es',
  'da',
];

/// The [Locale]s for [kSupportedLanguageCodes], wired into `MaterialApp`.
const List<Locale> kSupportedLocales = [
  Locale('en'),
  Locale('fr'),
  Locale('sv'),
  Locale('zh'),
  Locale('ja'),
  Locale('de'),
  Locale('pt'),
  Locale('es'),
  Locale('da'),
];

/// Resolves the effective [Locale] from an optional persisted [override] code,
/// the [system] locale, and the [supported] set, applying Stunda's rule:
/// a valid override wins; else the system language if supported; else English.
///
/// Pure so the resolution is unit-testable without a `MaterialApp`.
Locale resolveLocale({
  String? override,
  Locale? system,
  List<String> supported = kSupportedLanguageCodes,
}) {
  if (override != null && supported.contains(override)) return Locale(override);
  if (system != null && supported.contains(system.languageCode)) {
    return Locale(system.languageCode);
  }
  return const Locale('en');
}

/// The active translations, looked up by [tr].
///
/// Holds the loaded locale's `key → string` map plus the English fallback. Obtain
/// it with [AppLocalizations.of] (or, more conveniently, `context.tr('key')`).
class AppLocalizations {
  /// Creates a lookup over [strings] for [locale].
  AppLocalizations(this.locale, this.strings);

  /// The locale these strings belong to.
  final Locale locale;

  /// The loaded `key → string` map for [locale].
  final Map<String, String> strings;

  /// The nearest [AppLocalizations], or null when none is in scope (e.g. a
  /// bare-`MaterialApp` test). Callers should prefer [context.tr] which falls
  /// back to the English strings when this is null.
  static AppLocalizations? of(BuildContext context) =>
      Localizations.of<AppLocalizations>(context, AppLocalizations);

  /// The delegate that loads a locale's JSON asset.
  static const LocalizationsDelegate<AppLocalizations> delegate =
      AppLocalizationsDelegate();

  /// Looks up [key], substituting any `{placeholder}` with [params], falling
  /// back to the English value, then to [key] itself when truly unknown.
  String tr(String key, [Map<String, Object?>? params]) {
    final template = strings[key] ?? kEnglishStrings[key] ?? key;
    return _interpolate(template, params);
  }

  /// Substitutes `{name}` tokens in [template] with the matching [params] value;
  /// tokens without a param are left intact. Pure so it is unit-testable.
  static String _interpolate(String template, Map<String, Object?>? params) {
    if (params == null || params.isEmpty || !template.contains('{')) {
      return template;
    }
    return template.replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) {
      final name = m.group(1)!;
      return params.containsKey(name) ? '${params[name]}' : m.group(0)!;
    });
  }
}

/// Loads `assets/i18n/<code>.json` into an [AppLocalizations] for the locale.
class AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  /// Creates the delegate.
  const AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) =>
      kSupportedLanguageCodes.contains(locale.languageCode);

  @override
  Future<AppLocalizations> load(Locale locale) {
    final code = kSupportedLanguageCodes.contains(locale.languageCode)
        ? locale.languageCode
        : 'en';
    // English resolves SYNCHRONOUSLY from the bundled compile-time map (it is
    // identical to en.json), so the first frame already has localizations — no
    // extra pump needed in widget tests, and English (the fallback) is never a
    // frame late. Other locales load their JSON asset asynchronously.
    if (code == 'en') {
      return SynchronousFuture(
        AppLocalizations(const Locale('en'), kEnglishStrings),
      );
    }
    return _loadAsset(code);
  }

  Future<AppLocalizations> _loadAsset(String code) async {
    Map<String, String> strings;
    try {
      final raw = await rootBundle.loadString('assets/i18n/$code.json');
      final map = jsonDecode(raw) as Map<String, dynamic>;
      strings = {for (final e in map.entries) e.key: '${e.value}'};
    } on Object {
      // A missing/unreadable asset degrades to the compile-time English map so
      // the UI is never blank — every lookup still resolves through tr's
      // English fallback.
      strings = kEnglishStrings;
    }
    return AppLocalizations(Locale(code), strings);
  }

  @override
  bool shouldReload(AppLocalizationsDelegate old) => false;
}

/// Ergonomic `context.tr('key', {...})` shortcut.
///
/// Resolves through the nearest [AppLocalizations] when one is in scope; with no
/// delegate present (e.g. a bare-`MaterialApp` widget test) it falls back to the
/// compile-time English strings so UI text still renders.
extension AppLocalizationsX on BuildContext {
  /// Translates [key] with optional [params], English-fallback safe.
  String tr(String key, [Map<String, Object?>? params]) {
    final loc = AppLocalizations.of(this);
    if (loc != null) return loc.tr(key, params);
    return AppLocalizations._interpolate(kEnglishStrings[key] ?? key, params);
  }
}
