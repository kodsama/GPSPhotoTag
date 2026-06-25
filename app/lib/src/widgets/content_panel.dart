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
            const SizedBox(height: 10),
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

  static List<String> _supportedChips(FolderScanResult scan) {
    final chips = <String>[];
    final formats = scan.photosByFormat.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final e in formats) {
      chips.add('${e.key.toUpperCase()} ${_fmt(e.value)}');
    }
    if (scan.gpxCount > 0) chips.add('GPX ${_fmt(scan.gpxCount)}');
    if (scan.kmlCount > 0) chips.add('KML ${_fmt(scan.kmlCount)}');
    if (scan.googleCount > 0) {
      chips.add('Timeline ${_fmt(scan.googleCount)}');
    }
    if (chips.isEmpty) chips.add('Nothing supported found');
    return chips;
  }

  static String _fmt(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
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

/// A wrap of plain rounded count chips.
class _Chips extends StatelessWidget {
  const _Chips({required this.chips});

  final List<String> chips;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = scheme.onSurface;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final chip in chips)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: scheme.outline),
            ),
            child: Text(
              chip,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: color),
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
