/// Pure helpers for the multi-root library model.
///
/// A library is an ORDERED list of roots, where each root is either a directory
/// or a single image / GPS-source file. These functions are side-effect free
/// (except the explicit filesystem-type probe in [classifyDropped], injected in
/// tests) so they can be unit-tested without spawning isolates or touching the
/// real engine.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:stunda_engine/stunda_engine.dart';

/// Whether [path] is a root the library can scan: a directory OR a supported
/// file (a taggable photo or a GPS source). Files of other types are not roots.
bool isAddableRoot(String path, {bool isDirectory = false}) =>
    isDirectory || PhotoFormats.isSupported(path);

/// Returns [current] with [additions] appended, preserving order and dropping
/// duplicates (a path already present, or repeated within [additions]).
///
/// Order is the user's add order: existing roots keep their position and new
/// ones are appended in the order given.
List<String> addRoots(List<String> current, Iterable<String> additions) {
  final seen = current.toSet();
  final out = [...current];
  for (final path in additions) {
    if (seen.add(path)) out.add(path);
  }
  return out;
}

/// Returns [current] without [path] (order preserved). A no-op when absent.
List<String> removeRoot(List<String> current, String path) => [
  for (final root in current)
    if (root != path) root,
];

/// A compact, human label for a root: its basename, falling back to the full
/// path when the basename is empty (e.g. a filesystem root like `/`).
String rootLabel(String path) {
  final base = p.basename(path);
  return base.isEmpty ? path : base;
}

/// The outcome of classifying a batch of dropped (or otherwise added) paths.
class DroppedPaths {
  /// Wraps the three buckets.
  const DroppedPaths({
    required this.directories,
    required this.files,
    required this.ignored,
  });

  /// Dropped paths that are directories (become directory roots).
  final List<String> directories;

  /// Dropped paths that are supported files (become file roots).
  final List<String> files;

  /// Dropped paths that are neither a directory nor a supported file.
  final List<String> ignored;

  /// Directories + supported files, in that order — every path that should be
  /// merged into the library as a root.
  List<String> get accepted => [...directories, ...files];

  /// Whether nothing usable was dropped.
  bool get isEmpty => directories.isEmpty && files.isEmpty;
}

/// Classifies [paths] into {directories, supported files, ignored}.
///
/// [isDirectory] decides whether a path is a directory; it defaults to a real
/// filesystem probe but is injectable so the classification logic is unit-
/// testable without touching disk. A path that is not a directory is kept only
/// when [PhotoFormats.isSupported] accepts it (a photo or GPS source);
/// everything else (videos, unknown files, broken paths) is ignored gracefully.
DroppedPaths classifyDropped(
  Iterable<String> paths, {
  bool Function(String path)? isDirectory,
}) {
  final isDir = isDirectory ?? _isDirectoryOnDisk;
  final directories = <String>[];
  final files = <String>[];
  final ignored = <String>[];
  for (final path in paths) {
    if (isDir(path)) {
      directories.add(path);
    } else if (PhotoFormats.isSupported(path)) {
      files.add(path);
    } else {
      ignored.add(path);
    }
  }
  return DroppedPaths(directories: directories, files: files, ignored: ignored);
}

bool _isDirectoryOnDisk(String path) => FileSystemEntity.isDirectorySync(path);
