/// Seam for moving a file to the OS Trash/Recycle Bin.
///
/// Abstracted so the pruner can be tested without actually trashing files, and
/// so each desktop platform can supply its own real implementation.
abstract interface class Trash {
  /// Moves the file at [path] to the OS Trash. Throws on failure.
  Future<void> toTrash(String path);
}
