import 'package:flutter/material.dart';
import 'package:stunda_engine/stunda_engine.dart';

import '../i18n/app_localizations.dart';
import '../theme/app_theme.dart';
import 'file_list_dialog.dart';
import 'glass.dart';

/// One supported chip: a label, its files, and whether they are GPS sources.
class _ChipSpec {
  const _ChipSpec(this.label, this.paths, {required this.gps});

  final String label;
  final List<String> paths;
  final bool gps;

  int get count => paths.length;
}

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
    final text = Theme.of(context).textTheme;
    return GlassSurface(
      borderRadius: BorderRadius.circular(AppTheme.radius),
      child: Material(
        type: MaterialType.transparency,
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            initiallyExpanded: true,
            title: Text(context.tr('content_title'), style: text.titleMedium),
            childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
            children: [
              _SectionLabel(context.tr('content_supported')),
              const SizedBox(height: 12),
              _Chips(chips: _supportedChips(context, scan)),
              if (scan.unsupportedCount > 0) ...[
                const SizedBox(height: 20),
                _SectionLabel(context.tr('content_not_used'), muted: true),
                const SizedBox(height: 6),
                Text(
                  context.tr('content_not_used_explainer'),
                  style: text.bodySmall,
                ),
                const SizedBox(height: 10),
                _UnsupportedGroups(scan: scan),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Chip specs for the supported section: photo formats (by count desc) then
  /// GPS sources. Each carries the file paths behind it so a tap can open the
  /// drill-down dialog. Counts are plain integers — no thousands grouping.
  static List<_ChipSpec> _supportedChips(
    BuildContext context,
    FolderScanResult scan,
  ) {
    final chips = <_ChipSpec>[];
    final byFormat = <String, List<String>>{};
    for (final path in scan.photos) {
      byFormat.putIfAbsent(PhotoFormats.extOf(path), () => []).add(path);
    }
    final formats = byFormat.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    for (final e in formats) {
      chips.add(_ChipSpec(e.key.toUpperCase(), e.value, gps: false));
    }
    if (scan.gpxCount > 0) {
      chips.add(
        _ChipSpec(context.tr('content_chip_gpx'), scan.gpxFiles, gps: true),
      );
    }
    if (scan.kmlCount > 0) {
      chips.add(
        _ChipSpec(context.tr('content_chip_kml'), scan.kmlFiles, gps: true),
      );
    }
    if (scan.googleCount > 0) {
      chips.add(
        _ChipSpec(
          context.tr('content_chip_timeline'),
          scan.googleFiles,
          gps: true,
        ),
      );
    }
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
/// Each chip is tappable, opening the drill-down dialog for its files.
class _Chips extends StatelessWidget {
  const _Chips({required this.chips});

  final List<_ChipSpec> chips;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    if (chips.isEmpty) {
      return Text(
        context.tr('content_nothing_supported'),
        style: text.bodySmall?.copyWith(
          color: scheme.onSurface.withValues(alpha: 0.5),
        ),
      );
    }
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final chip in chips)
          Material(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(9),
            child: InkWell(
              borderRadius: BorderRadius.circular(9),
              onTap: () => showFileListDialog(
                context,
                title: context.tr('content_chip_title', {
                  'label': chip.label,
                  'count': chip.count,
                }),
                paths: chip.paths,
                supported: true,
                gps: chip.gps,
              ),
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 7, 7, 7),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: scheme.outline),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      chip.label,
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
                        '${chip.count}',
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

  static const _labelKeys = {
    UnsupportedCategory.image: 'content_cat_images',
    UnsupportedCategory.video: 'content_cat_videos',
    UnsupportedCategory.gpsData: 'content_cat_gps',
    UnsupportedCategory.other: 'content_cat_other',
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
              label: context.tr('content_category_label', {
                'label': context.tr(_labelKeys[cat]!),
                'count': byCat[cat],
              }),
              title: context.tr('content_category_title', {
                'label': context.tr(_labelKeys[cat]!),
                'count': byCat[cat],
              }),
              exts: _extsFor(scan, cat, byExt),
              paths: _pathsFor(scan, cat),
            ),
            const SizedBox(height: 8),
          ],
      ],
    );
  }

  /// The (capped) sample paths bucketed into [cat], for the read-only dialog.
  static List<String> _pathsFor(
    FolderScanResult scan,
    UnsupportedCategory cat,
  ) {
    return [
      for (final u in scan.unsupported)
        if (u.category == cat) u.path,
    ];
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

/// One muted "Images (12): tif, bmp…" row — tappable to open a read-only list.
class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.label,
    required this.title,
    required this.exts,
    required this.paths,
  });

  final String label;
  final String title;
  final List<String> exts;
  final List<String> paths;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final muted = scheme.onSurface.withValues(alpha: 0.5);
    final suffix = exts.isEmpty ? '' : ': ${exts.join(', ')}';
    return InkWell(
      onTap: paths.isEmpty
          ? null
          : () => showFileListDialog(
              context,
              title: title,
              paths: paths,
              supported: false,
              gps: false,
            ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(
          '$label$suffix',
          style: text.bodySmall?.copyWith(color: muted),
        ),
      ),
    );
  }
}
