import '../data/photo_formats.dart';

/// How a single photo path relates to the RAW/JPG pairing in a library.
enum PairKind {
  /// A RAW file with no JPG/HEIC companion anywhere in the tree — a deletion
  /// candidate.
  orphanRaw,

  /// A RAW file that has a same-basename JPG/HEIC companion somewhere.
  pairedRaw,

  /// A JPG/HEIC photo that has a same-basename RAW somewhere.
  photoWithRaw,

  /// A JPG/HEIC photo (or any non-RAW photo) with no same-basename RAW.
  photoWithoutRaw,
}

/// One classified photo path: its [path] and the [kind] it was bucketed into.
class PairedFile {
  /// Creates a paired-file record.
  const PairedFile({required this.path, required this.kind});

  /// The photo path.
  final String path;

  /// How this path relates to RAW/JPG pairing.
  final PairKind kind;
}

/// The result of classifying every photo path in a library by RAW/JPG pairing.
///
/// Pure data computed by [classifyPairing]; carries the classified [files] and
/// derived counts. [orphanRaws] are the deletion candidates the preview UI
/// pre-selects.
class RawPairing {
  /// Creates a pairing result.
  const RawPairing(this.files);

  /// Every input photo path, classified.
  final List<PairedFile> files;

  /// Paths of RAW files with no companion — the deletion candidates.
  List<String> get orphanRaws => [
    for (final f in files)
      if (f.kind == PairKind.orphanRaw) f.path,
  ];

  /// Number of orphan RAWs (deletion candidates).
  int get orphanCount => _count(PairKind.orphanRaw);

  /// Number of RAWs that have a JPG/HEIC companion.
  int get pairedRawCount => _count(PairKind.pairedRaw);

  /// Number of JPG/HEIC photos that have a matching RAW.
  int get photoWithRawCount => _count(PairKind.photoWithRaw);

  /// Number of JPG/HEIC photos with no matching RAW.
  int get photoWithoutRawCount => _count(PairKind.photoWithoutRaw);

  int _count(PairKind kind) {
    var n = 0;
    for (final f in files) {
      if (f.kind == kind) n++;
    }
    return n;
  }
}

/// Classifies every path in [photoPaths] by RAW/JPG pairing, tree-wide.
///
/// Pure and O(n): builds the set of lower-cased basenames (without extension)
/// of companion photos (jpg/jpeg/heic/heif) and the set of RAW basenames across
/// the whole list, then buckets each path. Matching is case-insensitive and
/// crosses folders (a companion in another directory still pairs a RAW). No I/O.
RawPairing classifyPairing(List<String> photoPaths) {
  final companionBases = <String>{};
  final rawBases = <String>{};
  for (final path in photoPaths) {
    final ext = PhotoFormats.extOf(path);
    if (PhotoFormats.companion.contains(ext)) {
      companionBases.add(_baseKey(path));
    } else if (PhotoFormats.raw.contains(ext)) {
      rawBases.add(_baseKey(path));
    }
  }

  final files = <PairedFile>[];
  for (final path in photoPaths) {
    final ext = PhotoFormats.extOf(path);
    final base = _baseKey(path);
    final PairKind kind;
    if (PhotoFormats.raw.contains(ext)) {
      kind = companionBases.contains(base)
          ? PairKind.pairedRaw
          : PairKind.orphanRaw;
    } else if (PhotoFormats.companion.contains(ext)) {
      kind = rawBases.contains(base)
          ? PairKind.photoWithRaw
          : PairKind.photoWithoutRaw;
    } else {
      // Non-RAW, non-companion photos (png, webp) have no RAW partner concept.
      kind = PairKind.photoWithoutRaw;
    }
    files.add(PairedFile(path: path, kind: kind));
  }
  return RawPairing(files);
}

/// Lower-cased basename without its extension, used to match companions.
///
/// Delegates to [PhotoFormats.baseKeyOf] so the separator-robust logic is
/// shared with [Pruner].
String _baseKey(String path) => PhotoFormats.baseKeyOf(path);
