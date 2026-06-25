import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:gpsphototag_engine/gpsphototag_engine.dart';
import 'package:path/path.dart' as p;

import '../engine/engine_runner.dart';
import '../engine/isolate_runner.dart';
import '../engine/mcp_service.dart';
import 'input_summary.dart';
import 'log_entry.dart';
import 'wizard_step.dart';

/// The single source of truth for the GPSPhotoTag GUI.
///
/// Holds the wizard position, toolkit results, the parsed input, all tag
/// options, live progress, the activity log, and the last run summary. Every
/// engine operation runs through an [IsolateRunner] (off the UI isolate) and
/// streams events back here, which are folded into observable state. Methods are
/// deliberately small; tests drive state directly via the test-only setters at
/// the bottom rather than spinning real isolates.
class AppController extends ChangeNotifier {
  /// Creates a controller. Inject a fake [runner], a [pickFolder] override,
  /// and/or a [probeToolkit] override in tests; all default to the real
  /// implementations.
  AppController({
    EngineRunner? runner,
    Future<String?> Function()? pickFolder,
    Future<List<ToolStatus>> Function()? probeToolkit,
    String? exiftoolBundleDir,
  }) : _pickFolder = pickFolder ?? getDirectoryPath,
       _exiftoolBundleDir = exiftoolBundleDir,
       _probeToolkit =
           probeToolkit ??
           (() => ToolkitChecker(
             ExiftoolRunner(
               const SystemProcessRunner(),
               ExiftoolInvocation.resolve(exiftoolBundleDir),
             ),
           ).check()),
       mcp = McpService(exiftoolBundleDir: exiftoolBundleDir) {
    _runner = runner;
  }

  EngineRunner? _runner;
  final Future<String?> Function() _pickFolder;
  final Future<List<ToolStatus>> Function() _probeToolkit;

  /// On-disk dir of the app-bundled exiftool, or null when none is bundled.
  final String? _exiftoolBundleDir;

  /// The always-on MCP server for LLM clients. Constructed eagerly (cheap), but
  /// only spawns its isolate when [McpService.start] is called from `main` — so
  /// tests that build an [AppController] never start a real server.
  final McpService mcp;

  /// Whether a bundled exiftool is present on disk.
  bool get hasBundledExiftool => _exiftoolBundleDir != null;

  /// The runner, lazily built once exiftool availability is known.
  EngineRunner get _engine => _runner ??= IsolateRunner(
    exiftoolAvailable: exiftoolAvailable,
    exiftoolBundleDir: _exiftoolBundleDir,
  );

  // --- Theme ---------------------------------------------------------------

  ThemeMode _themeMode = ThemeMode.system;

  /// The active theme mode.
  ThemeMode get themeMode => _themeMode;

  /// Sets the theme to light or dark explicitly.
  ///
  /// The header passes the *currently displayed* brightness so the first tap
  /// always flips what the user sees — even when starting from
  /// [ThemeMode.system] (where a naive dark↔light toggle could pick the mode
  /// that already matches the OS and appear to do nothing).
  void setDark(bool dark) {
    final target = dark ? ThemeMode.dark : ThemeMode.light;
    if (_themeMode == target) return;
    _themeMode = target;
    notifyListeners();
  }

  // --- Wizard --------------------------------------------------------------

  WizardStep _step = WizardStep.input;
  final Set<WizardStep> _completed = {};

  /// The currently expanded step.
  WizardStep get step => _step;

  /// Steps the user has finished (collapsed with a check).
  Set<WizardStep> get completedSteps => Set.unmodifiable(_completed);

  /// Whether [step] has been completed.
  bool isCompleted(WizardStep step) => _completed.contains(step);

  /// Jumps to a previously visited [target] (only completed steps are tappable).
  void goTo(WizardStep target) {
    if (target == _step) return;
    if (target.isBefore(_step) || _completed.contains(target)) {
      _step = target;
      notifyListeners();
    }
  }

  /// Marks the current step complete and advances to the next one.
  void completeAndAdvance() {
    if (!isStepSatisfied(_step)) return;
    _completed.add(_step);
    final next = _step.next;
    if (next != null) _step = next;
    notifyListeners();
  }

  /// Whether [step]'s Continue action should be enabled.
  bool isStepSatisfied(WizardStep step) => switch (step) {
    WizardStep.input => _summary.hasPhotos,
    WizardStep.review => includedCount > 0,
    WizardStep.options => true,
    WizardStep.output => _outputValid,
    WizardStep.run => _lastSummary != null,
    WizardStep.result => true,
  };

  // --- Environment self-check ----------------------------------------------

  /// User-facing message shown when exiftool couldn't start; the bundled copy
  /// (when present) is preferred over a misleading "missing on PATH".
  static const _exiftoolWarning =
      "ExifTool couldn't start, so RAW-embed, HEIC, and Fuji/Canon RAW "
      'timestamps are unavailable. JPEG, PNG, and RAW sidecars still work.';

  List<ToolStatus> _toolkit = const [];
  bool _checked = false;

  /// Whether exiftool is available (gates RAW-embed & HEIC), per the last
  /// [checkEnvironment]. False until the check has run.
  bool get exiftoolAvailable =>
      _toolkit.any((t) => t.id == 'exiftool' && t.present);

  String? _environmentWarning;

  /// A non-alarming warning to surface as a banner, or null when all is well.
  String? get environmentWarning => _environmentWarning;

  bool _warningDismissed = false;

  /// Whether the user has dismissed the [environmentWarning] banner.
  bool get warningDismissed => _warningDismissed;

  /// Hides the warning banner until the next launch.
  void dismissWarning() {
    if (_warningDismissed) return;
    _warningDismissed = true;
    notifyListeners();
  }

  /// Runs the silent startup environment probe once: launches exiftool `-ver`
  /// through the engine runner (the bundled copy when present). On success
  /// [environmentWarning] is null; on failure it is set to a clear, calm note.
  /// Idempotent — repeat calls are no-ops.
  Future<void> checkEnvironment() async {
    if (_checked) return;
    _checked = true;
    _toolkit = await _probeToolkit();
    _runner = null; // rebuild engine with fresh exiftool availability
    if (exiftoolAvailable) {
      _environmentWarning = null;
      _log('Environment OK: ExifTool ready');
    } else {
      _environmentWarning = _exiftoolWarning;
      _log('ExifTool unavailable', level: LogLevel.warning);
    }
    notifyListeners();
  }

  // --- Input ---------------------------------------------------------------

  InputSummary _summary = const InputSummary.empty();
  bool _parsing = false;
  final Map<String, bool> _included = {};

  /// The parsed folder summary.
  InputSummary get summary => _summary;

  /// Whether the folder is being scanned.
  bool get parsing => _parsing;

  /// Whether [path] is currently included in the run.
  bool isIncluded(String path) => _included[path] ?? true;

  /// Number of photos currently included.
  int get includedCount => _summary.photos.where(isIncluded).length;

  /// The included photo paths, in order.
  List<String> get includedPhotos =>
      _summary.photos.where(isIncluded).toList(growable: false);

  /// Opens a directory picker, then scans it.
  Future<void> pickInput() async {
    final folder = await _pickFolder();
    if (folder == null) return;
    await parseInput(folder);
  }

  /// Scans [folder] for photos and GPS sources off the UI isolate-light path.
  Future<void> parseInput(String folder) async {
    _parsing = true;
    notifyListeners();
    final photos = Collectors.photos([folder]);
    final gpx = Collectors.gpx([folder]);
    final google = Collectors.googleHistory([folder]);
    _summary = InputSummary.from(
      folder: folder,
      photos: photos,
      gpxFiles: gpx,
      googleFiles: google,
    );
    _included
      ..clear()
      ..addEntries(photos.map((path) => MapEntry(path, true)));
    _parsing = false;
    _log(
      'Scanned $folder: ${photos.length} photo(s), '
      '${gpx.length} GPX, ${google.length} Google file(s)',
    );
    notifyListeners();
  }

  /// Includes or excludes a single [path] from the run.
  void setIncluded(String path, bool included) {
    _included[path] = included;
    notifyListeners();
  }

  /// Includes or excludes every photo of [ext] at once.
  void setFormatIncluded(String ext, bool included) {
    for (final path in _summary.photos) {
      if (PhotoFormats.extOf(path) == ext) _included[path] = included;
    }
    notifyListeners();
  }

  // --- Tag options ---------------------------------------------------------

  bool _copyToFolder = false;
  String? _outDir;
  bool _replace = false;
  RawMode _rawMode = RawMode.auto;
  int _maxTimeDiffSeconds = 300;
  String? _timezone;
  bool _dryRun = false;

  /// Whether tagged copies go to a new folder (vs modifying originals).
  bool get copyToFolder => _copyToFolder;

  /// The chosen output directory (when [copyToFolder]).
  String? get outDir => _outDir;

  /// Whether to overwrite GPS already present in a photo.
  bool get replace => _replace;

  /// The RAW write strategy.
  RawMode get rawMode => _rawMode;

  /// Largest allowed gap, in seconds, between a photo and a GPS point.
  int get maxTimeDiffSeconds => _maxTimeDiffSeconds;

  /// Optional IANA timezone override.
  String? get timezone => _timezone;

  /// Whether to locate-and-report only, writing nothing.
  bool get dryRun => _dryRun;

  /// Toggles copy-to-folder mode, clearing the destination when turned off.
  void setCopyToFolder(bool value) {
    _copyToFolder = value;
    if (!value) _outDir = null;
    notifyListeners();
  }

  /// Sets the output directory.
  void setOutDir(String? dir) {
    _outDir = dir;
    notifyListeners();
  }

  /// Opens a directory picker and, if one is chosen, sets it as the output dir.
  Future<void> pickOutDir() async {
    final picked = await _pickFolder();
    if (picked != null) setOutDir(picked);
  }

  /// Toggles overwriting existing GPS.
  void setReplace(bool value) {
    _replace = value;
    notifyListeners();
  }

  /// Sets the RAW write strategy (embed is rejected without exiftool).
  void setRawMode(RawMode mode) {
    if (mode == RawMode.embed && !exiftoolAvailable) return;
    _rawMode = mode;
    notifyListeners();
  }

  /// Sets the max time difference in seconds (clamped to >= 0).
  void setMaxTimeDiff(int seconds) {
    _maxTimeDiffSeconds = seconds < 0 ? 0 : seconds;
    notifyListeners();
  }

  /// Sets (or clears, when blank) the timezone override.
  void setTimezone(String? tz) {
    _timezone = (tz == null || tz.trim().isEmpty) ? null : tz.trim();
    notifyListeners();
  }

  /// Toggles dry-run mode.
  void setDryRun(bool value) {
    _dryRun = value;
    notifyListeners();
  }

  /// Whether the chosen output is valid for a run.
  bool get _outputValid => _copyToFolder ? _outDir != null : true;

  /// Builds [TagOptions] from the current selections.
  TagOptions buildTagOptions() => TagOptions(
    outDir: _copyToFolder ? _outDir : null,
    overwrite: !_copyToFolder,
    replace: _replace,
    rawMode: _rawMode,
    maxTimeDiff: Duration(seconds: _maxTimeDiffSeconds),
    timezone: _timezone,
    dryRun: _dryRun,
  );

  // --- Run state -----------------------------------------------------------

  int _done = 0;
  int _total = 0;
  bool _running = false;
  String? _errorMessage;
  final List<PhotoRow> _rows = [];
  Map<String, int>? _lastSummary;
  StreamSubscription<EngineEvent>? _sub;

  /// Items completed so far in the current/last run.
  int get done => _done;

  /// Total items in the current/last run.
  int get total => _total;

  /// Progress fraction in 0..1.
  double get fraction => _total == 0 ? 0 : _done / _total;

  /// Whether an operation is currently running.
  bool get running => _running;

  /// The most recent fatal error, surfaced in the UI; null when none.
  String? get errorMessage => _errorMessage;

  /// The most recent per-item rows (newest first), capped for the live list.
  List<PhotoRow> get rows => List.unmodifiable(_rows);

  /// The status tally from the last completed operation.
  Map<String, int>? get lastSummary => _lastSummary;

  // --- Activity log --------------------------------------------------------

  final List<LogEntry> _logEntries = [];
  int _unread = 0;

  /// The activity-log entries, newest last.
  List<LogEntry> get logEntries => List.unmodifiable(_logEntries);

  /// Count of log entries added since the panel was last opened.
  int get unreadCount => _unread;

  /// Resets the unread badge (call when the panel opens).
  void markLogRead() {
    if (_unread == 0) return;
    _unread = 0;
    notifyListeners();
  }

  void _log(String message, {LogLevel level = LogLevel.info}) {
    _logEntries.add(LogEntry(message, level: level));
    _unread++;
  }

  // --- Operations ----------------------------------------------------------

  /// Tags the included photos, streaming events into state.
  Future<void> runTag() => _consume(
    _engine.tag(
      photos: includedPhotos,
      gpxFiles: _summary.gpxFiles,
      googleFiles: _summary.googleFiles,
      options: buildTagOptions(),
    ),
    startMessage: 'Tagging $includedCount photo(s)…',
    total: includedCount,
    onDone: () {
      if (_lastSummary != null && _step == WizardStep.run) {
        _completed.add(WizardStep.run);
        _step = WizardStep.result;
      }
    },
  );

  /// Renders a heatmap PNG into the picked folder; returns its path or null.
  Future<String?> renderMap() async {
    final folder = _summary.folder;
    if (folder == null) return null;
    final out = p.join(folder, 'gpsphototag-heatmap.png');
    await _consume(
      _engine.map(
        photos: _summary.photos,
        options: MapOptions(outputPng: out),
      ),
      startMessage: 'Rendering heatmap…',
      total: _summary.photos.length,
    );
    return _errorMessage == null ? out : null;
  }

  /// Prunes orphan RAW files under the picked folder.
  Future<void> runPrune({bool dryRun = false}) {
    final folder = _summary.folder;
    if (folder == null) return Future.value();
    return _consume(
      _engine.prune(
        roots: [folder],
        options: PruneOptions(dryRun: dryRun),
      ),
      startMessage: dryRun ? 'Previewing orphan RAWs…' : 'Pruning orphan RAWs…',
      total: 0,
    );
  }

  /// Fixes capture/file dates for the picked photos in [mode].
  Future<void> runFixDates(FixDatesMode mode, {bool dryRun = false}) =>
      _consume(
        _engine.fixDates(files: includedPhotos, mode: mode, dryRun: dryRun),
        startMessage: 'Fixing dates (${mode.name})…',
        total: includedCount,
      );

  /// Resets the run for a fresh folder, returning to the input step.
  void tagAnother() {
    _summary = const InputSummary.empty();
    _included.clear();
    _rows.clear();
    _lastSummary = null;
    _errorMessage = null;
    _done = 0;
    _total = 0;
    _completed.remove(WizardStep.result);
    _completed.remove(WizardStep.run);
    _completed.remove(WizardStep.input);
    _completed.remove(WizardStep.review);
    _step = WizardStep.input;
    notifyListeners();
  }

  /// Subscribes to [events], resetting run state and folding each event in.
  Future<void> _consume(
    Stream<EngineEvent> events, {
    required String startMessage,
    required int total,
    void Function()? onDone,
  }) async {
    await _sub?.cancel();
    _running = true;
    _errorMessage = null;
    _done = 0;
    _total = total;
    _rows.clear();
    _log(startMessage);
    notifyListeners();

    final completer = Completer<void>();
    _sub = events.listen(
      _handleEvent,
      onError: (Object e) {
        _errorMessage = '$e';
        _log('$e', level: LogLevel.error);
        _finish(completer);
      },
      onDone: () {
        onDone?.call();
        _finish(completer);
      },
    );
    return completer.future;
  }

  void _handleEvent(EngineEvent event) {
    switch (event) {
      case LogEvent(:final message, :final level):
        _log(message, level: level);
      case ProgressEvent(:final done, :final total):
        _done = done;
        if (total > 0) _total = total;
      case ItemEvent(:final row):
        _rows.insert(0, row);
        if (_rows.length > 200) _rows.removeLast();
      case DoneEvent(:final summary):
        _lastSummary = summary;
        _log(
          'Done: '
          '${summary.entries.map((e) => '${e.key}=${e.value}').join(', ')}',
        );
      case ErrorEvent(:final message):
        _errorMessage = message;
        _log(message, level: LogLevel.error);
    }
    notifyListeners();
  }

  void _finish(Completer<void> completer) {
    _running = false;
    notifyListeners();
    if (!completer.isCompleted) completer.complete();
  }

  @override
  void dispose() {
    _sub?.cancel();
    mcp.dispose();
    super.dispose();
  }

  // --- Test seams ----------------------------------------------------------

  /// Injects environment-probe results directly (tests only).
  @visibleForTesting
  void debugSetToolkit(List<ToolStatus> statuses) {
    _toolkit = statuses;
    notifyListeners();
  }

  /// Injects a parsed input summary directly (tests only).
  @visibleForTesting
  void debugSetSummary(InputSummary summary) {
    _summary = summary;
    _included
      ..clear()
      ..addEntries(summary.photos.map((path) => MapEntry(path, true)));
    notifyListeners();
  }

  /// Forces the active step (tests only).
  @visibleForTesting
  void debugSetStep(WizardStep step, {Set<WizardStep>? completed}) {
    _step = step;
    if (completed != null) {
      _completed
        ..clear()
        ..addAll(completed);
    }
    notifyListeners();
  }

  /// Appends a log entry directly (tests only).
  @visibleForTesting
  void debugAddLog(String message, {LogLevel level = LogLevel.info}) {
    _log(message, level: level);
    notifyListeners();
  }
}
