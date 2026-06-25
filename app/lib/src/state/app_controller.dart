import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:path/path.dart' as p;

import '../engine/engine_runner.dart';
import '../engine/isolate_runner.dart';
import '../engine/mcp_service.dart';
import '../explore/explore_model.dart';
import 'app_prefs.dart';
import 'app_screen.dart';
import 'library_action.dart';
import 'log_entry.dart';

/// The single source of truth for the Stunda GUI.
///
/// Models the app as a hub-and-spoke workspace: the user picks a photo library
/// ([AppScreen.welcome]), watches it scan ([AppScreen.scanning]), lands on the
/// hub ([AppScreen.workspace]), then opens a focused action ([AppScreen.action])
/// and returns. The scan result, the selected [LibraryAction], all tag options,
/// live run progress, the activity log, and the last run summary live here.
/// Every engine operation runs through an [EngineRunner] (off the UI isolate)
/// and streams events back, which are folded into observable state. Tests drive
/// state directly via the test-only setters at the bottom.
class AppController extends ChangeNotifier {
  /// Creates a controller. Inject a fake [runner], a [pickFolder] override,
  /// and/or a [probeToolkit] override in tests; all default to real impls.
  AppController({
    EngineRunner? runner,
    Future<String?> Function()? pickFolder,
    Future<List<ToolStatus>> Function()? probeToolkit,
    String? exiftoolBundleDir,
    AppPrefs? prefs,
  }) : _pickFolder = pickFolder ?? getDirectoryPath,
       _exiftoolBundleDir = exiftoolBundleDir,
       _prefs = prefs,
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
    if (prefs != null) {
      _themeMode = prefs.themeMode;
      _rawMode = prefs.defaultRawMode;
      _maxTimeDiffSeconds = prefs.defaultMaxTimeDiffSeconds;
    }
  }

  EngineRunner? _runner;
  final Future<String?> Function() _pickFolder;
  final Future<List<ToolStatus>> Function() _probeToolkit;

  /// Persisted preferences (theme + tag defaults), or null when persistence is
  /// disabled (most tests). Changes are written back through it.
  final AppPrefs? _prefs;

  /// On-disk dir of the app-bundled exiftool, or null when none is bundled.
  final String? _exiftoolBundleDir;

  /// The always-on MCP server for LLM clients. Constructed eagerly (cheap), but
  /// only spawns its isolate when [McpService.start] is called from `main`.
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

  /// Sets the theme mode explicitly and persists the choice.
  void setThemeMode(ThemeMode mode) {
    if (_themeMode == mode) return;
    _themeMode = mode;
    _persistPrefs();
    notifyListeners();
  }

  /// Sets the theme to light or dark explicitly, persisting the choice.
  ///
  /// The header passes the *currently displayed* brightness so the first tap
  /// always flips what the user sees — even from [ThemeMode.system].
  void setDark(bool dark) =>
      setThemeMode(dark ? ThemeMode.dark : ThemeMode.light);

  // --- Tag defaults (persisted) --------------------------------------------

  /// The persisted default RAW mode new tag runs start from.
  RawMode get defaultRawMode => _prefs?.defaultRawMode ?? RawMode.auto;

  /// The persisted default max time-difference (seconds) tag runs start from.
  int get defaultMaxTimeDiffSeconds => _prefs?.defaultMaxTimeDiffSeconds ?? 300;

  /// Sets the persisted default RAW mode (embed is rejected without exiftool),
  /// applying it to the current tag options too.
  void setDefaultRawMode(RawMode mode) {
    if (mode == RawMode.embed && !exiftoolAvailable) return;
    _prefs?.defaultRawMode = mode;
    _rawMode = mode;
    _persistPrefs();
    notifyListeners();
  }

  /// Sets the persisted default max time-difference (clamped to >= 0), applying
  /// it to the current tag options too.
  void setDefaultMaxTimeDiff(int seconds) {
    final clamped = seconds < 0 ? 0 : seconds;
    _prefs?.defaultMaxTimeDiffSeconds = clamped;
    _maxTimeDiffSeconds = clamped;
    _persistPrefs();
    notifyListeners();
  }

  void _persistPrefs() {
    final prefs = _prefs;
    if (prefs == null) return;
    prefs.themeMode = _themeMode;
    prefs.save();
  }

  // --- Screen navigation ---------------------------------------------------

  AppScreen _screen = AppScreen.welcome;
  LibraryAction? _action;

  /// The screen currently shown.
  AppScreen get screen => _screen;

  /// The action whose focused panel is open (only on [AppScreen.action]).
  LibraryAction? get action => _action;

  /// Opens the focused panel for [action] (resets any prior run state).
  ///
  /// Destructive actions preview first: opening [LibraryAction.pruneRaw]
  /// classifies the library (cheap, in-process) so the panel can show a
  /// reviewable, selectable list — nothing is removed until the user confirms.
  void openAction(LibraryAction action) {
    // The Explore map is a full screen, not an action panel: route it there and
    // start loading coordinates.
    if (action == LibraryAction.explore) {
      openExplore();
      return;
    }
    _action = action;
    _resetRun();
    if (action == LibraryAction.pruneRaw) {
      _preparePruneReview();
    } else {
      _pairing = null;
    }
    _screen = AppScreen.action;
    notifyListeners();
  }

  /// Returns from an action panel to the workspace hub.
  void backToLibrary() {
    _action = null;
    _resetRun();
    _screen = AppScreen.workspace;
    notifyListeners();
  }

  /// Drops the current library and returns to the welcome screen.
  void changeLibrary() {
    _sub?.cancel();
    _metaSub?.cancel();
    _exploreSub?.cancel();
    _explorePhotos.clear();
    _exploreLoading = false;
    _scan = null;
    _action = null;
    _resetRun();
    _excludedFiles.clear();
    _meta.clear();
    _metaLoading.clear();
    _scanProgress = null;
    _running = false;
    _screen = AppScreen.welcome;
    notifyListeners();
  }

  // --- Environment self-check ----------------------------------------------

  /// User-facing message shown when exiftool couldn't start.
  static const _exiftoolWarning =
      "ExifTool couldn't start, so RAW-embed, HEIC, and Fuji/Canon RAW "
      'timestamps are unavailable. JPEG, PNG, and RAW sidecars still work.';

  List<ToolStatus> _toolkit = const [];
  bool _checked = false;

  /// Whether exiftool is available (gates RAW-embed & HEIC).
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

  /// Runs the silent startup environment probe once.
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

  // --- Library scan --------------------------------------------------------

  String? _folder;
  FolderScanResult? _scan;
  ScanProgress? _scanProgress;
  StreamSubscription<ScanEvent>? _scanSub;

  /// The picked library folder, or null when none is chosen.
  String? get folder => _folder;

  /// The library folder's basename, for compact display.
  String? get folderName => _folder == null ? null : p.basename(_folder!);

  /// The completed scan result, or null until a scan finishes.
  FolderScanResult? get scan => _scan;

  /// Live running totals while a scan is in flight, or null otherwise.
  ScanProgress? get scanProgress => _scanProgress;

  /// Opens the folder picker; if one is chosen, starts scanning it.
  Future<void> pickLibrary() async {
    final picked = await _pickFolder();
    if (picked == null) return;
    await startScan(picked);
  }

  /// Scans [folder] off the UI isolate, folding progress in, then lands on the
  /// workspace when the [ScanDoneEvent] arrives.
  Future<void> startScan(String folder) async {
    await _scanSub?.cancel();
    _folder = folder;
    _scan = null;
    _scanProgress = const ScanProgress();
    _screen = AppScreen.scanning;
    _log('Scanning $folder…');
    notifyListeners();

    final completer = Completer<void>();
    _scanSub = _engine
        .scan([folder])
        .listen(
          _handleScanEvent,
          onError: (Object e) {
            _log('Scan error: $e', level: LogLevel.error);
            if (!completer.isCompleted) completer.complete();
          },
          onDone: () {
            if (!completer.isCompleted) completer.complete();
          },
        );
    return completer.future;
  }

  void _handleScanEvent(ScanEvent event) {
    switch (event) {
      case ScanProgressEvent(:final progress):
        _scanProgress = progress;
      case ScanDoneEvent(:final result):
        _scan = result;
        _scanProgress = null;
        _screen = AppScreen.workspace;
        _log(
          'Scan done: ${result.photoCount} photos, '
          '${result.trackCount} tracks, ${result.googleCount} Timeline, '
          '${result.unsupportedCount} unsupported',
        );
      case ScanLogEvent(:final message):
        _log(message, level: LogLevel.debug);
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
  bool get outputValid => _copyToFolder ? _outDir != null : true;

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

  // --- File selection (drill-down include/exclude) -------------------------

  /// Files (photos AND GPS-source files) the user has unticked in a drill-down
  /// dialog. Excluded paths are filtered out of every action below.
  final Set<String> _excludedFiles = {};

  /// The set of paths excluded from processing (read-only view).
  Set<String> get excludedFiles => Set.unmodifiable(_excludedFiles);

  /// Whether [path] will be processed (i.e. it is not excluded).
  bool isFileIncluded(String path) => !_excludedFiles.contains(path);

  /// Includes ([included] true) or excludes a single [path].
  void setFileIncluded(String path, bool included) {
    final changed = included
        ? _excludedFiles.remove(path)
        : _excludedFiles.add(path);
    if (changed) notifyListeners();
  }

  /// Includes or excludes every path in [paths] at once (select-all/none).
  void setGroupIncluded(Iterable<String> paths, bool included) {
    var changed = false;
    for (final path in paths) {
      changed |= included
          ? _excludedFiles.remove(path)
          : _excludedFiles.add(path);
    }
    if (changed) notifyListeners();
  }

  /// [paths] with every excluded entry removed, order preserved.
  List<String> _included(List<String> paths) => [
    for (final path in paths)
      if (!_excludedFiles.contains(path)) path,
  ];

  // --- File metadata cache (drill-down rows) -------------------------------

  final Map<String, FileMeta> _meta = {};
  final Set<String> _metaLoading = {};
  StreamSubscription<FileMeta>? _metaSub;

  /// Cached metadata for [path], or null if not read yet.
  FileMeta? fileMeta(String path) => _meta[path];

  /// Whether an image-metadata read is currently streaming in.
  bool get metaLoading => _metaLoading.isNotEmpty;

  /// Loads (and caches) image metadata for any of [paths] not already read.
  ///
  /// Streams results through [EngineRunner.readImageMeta] off the UI isolate,
  /// folding each [FileMeta] into the cache as it arrives so a dialog can show
  /// rows filling in progressively. Re-opening a group is instant: paths whose
  /// metadata is cached (or already loading) are skipped.
  Future<void> loadImageMeta(List<String> paths) async {
    final pending = [
      for (final path in paths)
        if (!_meta.containsKey(path) && !_metaLoading.contains(path)) path,
    ];
    if (pending.isEmpty) return;
    _metaLoading.addAll(pending);
    notifyListeners();

    await _metaSub?.cancel();
    final completer = Completer<void>();
    _metaSub = _engine
        .readImageMeta(pending)
        .listen(
          (meta) {
            _meta[meta.path] = meta;
            _metaLoading.remove(meta.path);
            notifyListeners();
          },
          onError: (Object _) {
            _metaLoading.removeAll(pending);
            notifyListeners();
            if (!completer.isCompleted) completer.complete();
          },
          onDone: () {
            _metaLoading.removeAll(pending);
            notifyListeners();
            if (!completer.isCompleted) completer.complete();
          },
        );
    return completer.future;
  }

  /// Reads GPS-source metadata for [paths] synchronously into the cache.
  ///
  /// Source-file parsing is cheap and pure, so it runs in-process; results are
  /// cached so re-opening the dialog is instant.
  void loadGpsMeta(List<String> paths) {
    var changed = false;
    for (final path in paths) {
      if (_meta.containsKey(path)) continue;
      _meta[path] = gpsFileMeta(path);
      changed = true;
    }
    if (changed) notifyListeners();
  }

  // --- Explore map ---------------------------------------------------------

  final List<ExplorePhoto> _explorePhotos = [];
  int _exploreLoaded = 0;
  int _exploreTotal = 0;
  bool _exploreLoading = false;
  StreamSubscription<FileMeta>? _exploreSub;
  String? _exploreFocusPath;

  /// Geotagged photos discovered so far for the Explore map (grows as
  /// coordinates stream in).
  List<ExplorePhoto> get explorePhotos => List.unmodifiable(_explorePhotos);

  /// Photos whose metadata has been read so far (for the "loading N/M" chip).
  int get exploreLoaded => _exploreLoaded;

  /// Total photos being read for the Explore map.
  int get exploreTotal => _exploreTotal;

  /// Whether coordinates are still streaming in.
  bool get exploreLoading => _exploreLoading;

  /// A photo path the Explore screen should focus (open its detail) once
  /// loaded, set by [openExploreAt]. The screen reads and clears it.
  String? get exploreFocusPath => _exploreFocusPath;

  /// Clears the pending deep-link focus once the screen has consumed it.
  void clearExploreFocus() => _exploreFocusPath = null;

  /// Opens the Explore map and starts loading every included photo's
  /// coordinates off the UI isolate. [focusPath], when given, is remembered so
  /// the screen can open that photo's detail panel.
  void openExplore({String? focusPath}) {
    _screen = AppScreen.explore;
    _exploreFocusPath = focusPath;
    notifyListeners();
    _loadExploreCoordinates();
  }

  /// Deep-links into the Explore map focused on [path] (camera centered +
  /// zoomed, detail panel open). Threaded from the file-list dialog's pin icon.
  void openExploreAt(String path) => openExplore(focusPath: path);

  /// Leaves the Explore map, returning to the workspace hub.
  void closeExplore() {
    _exploreSub?.cancel();
    _exploreLoading = false;
    _screen = AppScreen.workspace;
    notifyListeners();
  }

  void _loadExploreCoordinates() {
    final scan = _scan;
    if (scan == null) return;
    final photos = _included(scan.photos);
    _explorePhotos.clear();
    _exploreLoaded = 0;
    _exploreTotal = photos.length;
    _exploreLoading = photos.isNotEmpty;
    notifyListeners();
    if (photos.isEmpty) return;

    // Reuse any coordinates already cached from a drill-down; only read the
    // rest. Cached ones count as loaded immediately.
    final pending = <String>[];
    for (final path in photos) {
      final cached = _meta[path];
      if (cached != null) {
        _exploreLoaded++;
        final ep = ExplorePhoto.fromMeta(cached);
        if (ep != null) _explorePhotos.add(ep);
      } else {
        pending.add(path);
      }
    }
    if (pending.isEmpty) {
      _exploreLoading = false;
      notifyListeners();
      return;
    }
    notifyListeners();

    _exploreSub?.cancel();
    _exploreSub = _engine
        .readImageMeta(pending)
        .listen(
          (meta) {
            _meta[meta.path] = meta;
            _exploreLoaded++;
            final ep = ExplorePhoto.fromMeta(meta);
            if (ep != null) _explorePhotos.add(ep);
            notifyListeners();
          },
          onError: (Object _) {
            _exploreLoading = false;
            notifyListeners();
          },
          onDone: () {
            _exploreLoading = false;
            notifyListeners();
          },
        );
  }

  // --- Operations ----------------------------------------------------------

  /// Number of photos the tag run will process (after exclusions).
  int get photoCount => _included(_scan?.photos ?? const []).length;

  /// Tags every *included* scanned photo, pooling included GPS sources.
  Future<void> runTag() {
    final scan = _scan;
    if (scan == null) return Future.value();
    final photos = _included(scan.photos);
    return _consume(
      _engine.tag(
        photos: photos,
        gpxFiles: _included(scan.gpxFiles),
        kmlFiles: _included(scan.kmlFiles),
        googleFiles: _included(scan.googleFiles),
        options: buildTagOptions(),
      ),
      startMessage: _dryRun
          ? 'Previewing ${photos.length} photo(s)…'
          : 'Tagging ${photos.length} photo(s)…',
      total: photos.length,
    );
  }

  /// Renders a heatmap PNG into the library folder; returns its path or null.
  Future<String?> renderMap({int? dpi}) async {
    final folder = _folder;
    final scan = _scan;
    if (folder == null || scan == null) return null;
    final photos = _included(scan.photos);
    final out = p.join(folder, 'stunda-heatmap.png');
    await _consume(
      _engine.map(
        photos: photos,
        options: MapOptions(outputPng: out, dpi: dpi ?? 200),
      ),
      startMessage: 'Rendering heatmap…',
      total: photos.length,
    );
    return _errorMessage == null ? out : null;
  }

  // --- Prune review (preview → select → confirm → execute) -----------------

  RawPairing? _pairing;
  final Set<String> _selected = {};
  String _pruneFilter = '';
  // Which pair kinds are visible in the review list. Candidates (orphan RAWs)
  // are on by default; context rows are off to keep the list focused.
  final Set<PairKind> _visibleKinds = {PairKind.orphanRaw};

  /// The classified library for the prune review, or null when not reviewing.
  RawPairing? get pairing => _pairing;

  /// The orphan-RAW paths currently selected for trashing.
  Set<String> get selectedPaths => Set.unmodifiable(_selected);

  /// Number of orphan RAWs selected for trashing.
  int get selectedCount => _selected.length;

  /// The current filename filter (case-insensitive substring).
  String get pruneFilter => _pruneFilter;

  /// Whether [kind] rows are shown in the review list.
  bool isKindVisible(PairKind kind) => _visibleKinds.contains(kind);

  /// Classifies the scanned library and pre-selects every orphan RAW.
  ///
  /// Cheap and pure (no I/O): [classifyPairing] is O(n) over the scan's photo
  /// paths. Pre-selecting orphans matches the user's default intent while still
  /// letting them deselect before confirming.
  void _preparePruneReview() {
    final scan = _scan;
    _pairing = scan == null ? null : classifyPairing(scan.photos);
    _selected
      ..clear()
      ..addAll(_pairing?.orphanRaws ?? const []);
    _pruneFilter = '';
    _visibleKinds
      ..clear()
      ..add(PairKind.orphanRaw);
  }

  /// The review rows after applying the visible-kind toggles and filename
  /// filter, in the scan's original order.
  List<PairedFile> get filteredPairing {
    final pairing = _pairing;
    if (pairing == null) return const [];
    final needle = _pruneFilter.toLowerCase();
    return [
      for (final f in pairing.files)
        if (_visibleKinds.contains(f.kind) &&
            (needle.isEmpty || _basename(f.path).contains(needle)))
          f,
    ];
  }

  String _basename(String path) => p.basename(path).toLowerCase();

  /// Sets the filename filter (case-insensitive substring match).
  void setPruneFilter(String value) {
    _pruneFilter = value;
    notifyListeners();
  }

  /// Shows or hides [kind] rows in the review list.
  void setKindVisible(PairKind kind, bool visible) {
    if (visible) {
      _visibleKinds.add(kind);
    } else {
      _visibleKinds.remove(kind);
    }
    notifyListeners();
  }

  /// Toggles whether a single orphan-RAW [path] is selected for trashing.
  void toggleSelected(String path, bool selected) {
    if (selected) {
      _selected.add(path);
    } else {
      _selected.remove(path);
    }
    notifyListeners();
  }

  /// Selects ([all] true) or clears every orphan RAW.
  void selectAllOrphans(bool all) {
    _selected.clear();
    if (all) _selected.addAll(_pairing?.orphanRaws ?? const []);
    notifyListeners();
  }

  /// Trashes the user-selected orphan RAWs after an explicit confirm.
  ///
  /// Only reached once the user has reviewed the preview and confirmed — the
  /// destructive-actions-preview-first principle. Sends exactly the selected
  /// paths (plus their sidecars, handled in the engine) to the Trash.
  Future<void> runTrashSelected() {
    if (_selected.isEmpty) return Future.value();
    final paths = _selected.toList(growable: false);
    return _consume(
      _engine.trashPaths(paths),
      startMessage: 'Moving ${paths.length} RAW file(s) to Trash…',
      total: paths.length,
    );
  }

  void _resetRun() {
    _rows.clear();
    _lastSummary = null;
    _errorMessage = null;
    _done = 0;
    _total = 0;
  }

  /// Subscribes to [events], resetting run state and folding each event in.
  Future<void> _consume(
    Stream<EngineEvent> events, {
    required String startMessage,
    required int total,
  }) async {
    await _sub?.cancel();
    _running = true;
    _errorMessage = null;
    _done = 0;
    _total = total;
    _rows.clear();
    _lastSummary = null;
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
      onDone: () => _finish(completer),
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
    _scanSub?.cancel();
    _sub?.cancel();
    _metaSub?.cancel();
    _exploreSub?.cancel();
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

  /// Lands the app on the workspace with [scan] as the library (tests only).
  @visibleForTesting
  void debugSetScan(FolderScanResult scan, {String folder = '/library'}) {
    _folder = folder;
    _scan = scan;
    _scanProgress = null;
    _screen = AppScreen.workspace;
    notifyListeners();
  }

  /// Forces the active screen and optional action (tests only).
  @visibleForTesting
  void debugSetScreen(AppScreen screen, {LibraryAction? action}) {
    _screen = screen;
    _action = action;
    if (action == LibraryAction.pruneRaw) _preparePruneReview();
    notifyListeners();
  }

  /// Seeds the metadata cache for [meta]'s path directly (tests only).
  @visibleForTesting
  void debugSeedMeta(FileMeta meta) {
    _meta[meta.path] = meta;
    notifyListeners();
  }

  /// Appends a log entry directly (tests only).
  @visibleForTesting
  void debugAddLog(String message, {LogLevel level = LogLevel.info}) {
    _log(message, level: level);
    notifyListeners();
  }

  /// Seeds the Explore map with [photos] on the explore screen, bypassing the
  /// isolate-backed coordinate read (tests only).
  @visibleForTesting
  void debugSetExplore(
    List<ExplorePhoto> photos, {
    String? focusPath,
    bool loading = false,
  }) {
    _screen = AppScreen.explore;
    _explorePhotos
      ..clear()
      ..addAll(photos);
    _exploreLoaded = photos.length;
    _exploreTotal = photos.length;
    _exploreLoading = loading;
    _exploreFocusPath = focusPath;
    notifyListeners();
  }
}
