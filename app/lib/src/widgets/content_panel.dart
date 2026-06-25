import 'package:flutter/material.dart';
import 'package:gpsphototag_engine/gpsphototag_engine.dart';

import '../theme/app_theme.dart';

/// An expandable breakdown of what the scan found: a *Supported* section
/// (photo formats + GPS sources that will be used) and a muted *Found but not
/// used* section grouping unsupported files by category. Default-open.
class ContentPanel extends StatelessWidget {
  /// Builds the panel over [scan].
  const ContentPanel({super.key, required this.scan});

  /// The scanned library.
  final FolderScanResult scan;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Material(
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radius),
        side: BorderSide(color: scheme.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: true,
          title: Text('Library contents', style: text.titleMedium),
          childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
          children: [
            _SectionLabel('Supported — will be used'),
            const SizedBox(height: 12),
            _Chips(chips: _supportedChips(scan)),
            if (scan.unsupportedCount > 0) ...[
              const SizedBox(height: 20),
              _SectionLabel('Found but not used', muted: true),
              const SizedBox(height: 6),
              Text(
                'Detected in the folder but not processed by GPSPhotoTag.',
                style: text.bodySmall,
              ),
              const SizedBox(height: 10),
              _UnsupportedGroups(scan: scan),
            ],
          ],
        ),
      ),
    );
  }

  /// (label, count) pairs for the supported chips: photo formats (by count
  /// desc) then GPS sources. Counts are plain integers — no thousands grouping.
  static List<(String, int)> _supportedChips(FolderScanResult scan) {
    final chips = <(String, int)>[];
    final formats = scan.photosByFormat.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final e in formats) {
      chips.add((e.key.toUpperCase(), e.value));
    }
    if (scan.gpxCount > 0) chips.add(('GPX', scan.gpxCount));
    if (scan.kmlCount > 0) chips.add(('KML', scan.kmlCount));
    if (scan.googleCount > 0) chips.add(('Timeline', scan.googleCount));
    return chips;
  }
}

/// A small uppercase section label, optionally muted.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label, {this.muted = false});

  final String label;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = muted
        ? scheme.onSurface.withValues(alpha: 0.5)
        : scheme.onSurface;
    return Text(
      label.toUpperCase(),
      style: Theme.of(
        context,
      ).textTheme.labelMedium?.copyWith(color: color, letterSpacing: 0.8),
    );
  }
}

/// A wrap of count chips: a bold format/source label on the left and the count
/// as a distinct pill on the right, so the two never visually run together.
class _Chips extends StatelessWidget {
  const _Chips({required this.chips});

  final List<(String, int)> chips;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    if (chips.isEmpty) {
      return Text(
        'Nothing supported found.',
        style: text.bodySmall?.copyWith(
          color: scheme.onSurface.withValues(alpha: 0.5),
        ),
      );
    }
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final (label, count) in chips)
          Container(
            padding: const EdgeInsets.fromLTRB(12, 7, 7, 7),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: scheme.outline),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: text.labelLarge?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 9),
                // Count in its own subtle pill, well clear of the label.
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '$count',
                    style: text.bodySmall?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                      fontFeatures: AppTheme.tabular,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The muted unsupported breakdown, one row per non-empty category.
class _UnsupportedGroups extends StatelessWidget {
  const _UnsupportedGroups({required this.scan});

  final FolderScanResult scan;

  static const _labels = {
    UnsupportedCategory.image: 'Images',
    UnsupportedCategory.video: 'Videos',
    UnsupportedCategory.gpsData: 'GPS data',
    UnsupportedCategory.other: 'Other',
  };

  @override
  Widget build(BuildContext context) {
    final byCat = scan.unsupportedByCategory;
    final byExt = scan.unsupportedByExtension;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final cat in UnsupportedCategory.values)
          if ((byCat[cat] ?? 0) > 0) ...[
            _CategoryRow(
              label: '${_labels[cat]} (${byCat[cat]})',
              exts: _extsFor(scan, cat, byExt),
            ),
            const SizedBox(height: 8),
          ],
      ],
    );
  }

  /// Up to a few sample extensions seen in [cat], from the capped sample list.
  static List<String> _extsFor(
    FolderScanResult scan,
    UnsupportedCategory cat,
    Map<String, int> byExt,
  ) {
    final exts = <String>{
      for (final u in scan.unsupported)
        if (u.category == cat) _extOf(u.path),
    }..remove('');
    final sorted = exts.toList()
      ..sort((a, b) => (byExt[b] ?? 0).compareTo(byExt[a] ?? 0));
    return sorted.take(6).toList();
  }

  static String _extOf(String path) {
    final slash = path.lastIndexOf(RegExp(r'[/\\]'));
    final base = slash < 0 ? path : path.substring(slash + 1);
    final dot = base.lastIndexOf('.');
    return dot <= 0 ? '' : base.substring(dot + 1).toLowerCase();
  }
}

/// One muted "Images (12): tif, bmp…" row.
class _CategoryRow extends StatelessWidget {
  const _CategoryRow({required this.label, required this.exts});

  final String label;
  final List<String> exts;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final muted = scheme.onSurface.withValues(alpha: 0.5);
    final suffix = exts.isEmpty ? '' : ': ${exts.join(', ')}';
    return Text('$label$suffix', style: text.bodySmall?.copyWith(color: muted));
  }
}
