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

/// Returns [current] with [additions] merged in, preserving add order and
/// keeping the set free of redundant roots via CONTAINMENT-aware dedup:
///
///  * An addition already COVERED by an existing directory root — equal to it,
///    or nested inside it — is skipped: it is already scanned through the
///    parent (e.g. adding `/pics/trip` or `/pics/a.jpg` when `/pics` is a
///    root). An exact duplicate of any existing root is likewise skipped.
///  * A directory addition that CONTAINS existing roots SUBSUMES them: the now
///    redundant nested children / files are dropped and the new ancestor is
///    appended in add order.
///
/// Containment uses canonical paths (so trailing-slash / `./` / `..` forms of
/// the same path agree) and [p.isWithin]. [isDirectory] probes whether a path
/// is a directory (needed because only directory roots can contain others); it
/// defaults to a real filesystem check but is injectable for tests.
List<String> addRoots(
  List<String> current,
  Iterable<String> additions, {
  bool Function(String path)? isDirectory,
}) {
  final isDir = isDirectory ?? _isDirectoryOnDisk;
  final out = [...current];

  for (final path in additions) {
    final key = _canonical(path);
    // Skip when already covered by (equal to, or nested inside) an existing
    // directory root, or an exact duplicate of any existing root.
    final covered = out.any((root) {
      final rootKey = _canonical(root);
      if (rootKey == key) return true;
      return isDir(root) && p.isWithin(rootKey, key);
    });
    if (covered) continue;

    // A new directory subsumes any existing roots nested inside it.
    if (isDir(path)) {
      out.removeWhere((root) => p.isWithin(key, _canonical(root)));
    }
    out.add(path);
  }
  return out;
}

/// Canonical (absolute + normalized) form of [path] for containment checks.
/// Never touches the filesystem and never throws on a broken path.
String _canonical(String path) => p.canonicalize(path);

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
