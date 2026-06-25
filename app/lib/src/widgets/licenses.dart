/// A curated licenses page: Stunda's own license plus the notable attached
/// software (one entry per component — not the per-package/per-file dump that
/// Flutter's default license page produces).
library;

import 'package:flutter/material.dart';

const _gpl = '''Stunda
Copyright (C) 2026 Kodsama

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU General Public License for more details.

Full text: the LICENSE file in the repository.''';

/// One attached component (listed once, by component).
class _Component {
  const _Component(this.name, this.license, this.role);

  /// Component name.
  final String name;

  /// License identifier(s).
  final String license;

  /// What the component does for Stunda.
  final String role;
}

const _attached = <_Component>[
  _Component(
    'ExifTool',
    'Artistic / GPL',
    'RAW/HEIC metadata read & GPS embed (bundled)',
  ),
  _Component('Flutter & Dart', 'BSD-3-Clause', 'App framework & language'),
  _Component(
    'flutter_map + OpenStreetMap tiles',
    'BSD-3 / © OpenStreetMap contributors',
    'Interactive map',
  ),
  _Component(
    'flutter_map_marker_cluster + latlong2',
    'MIT / BSD',
    'Map clustering & coordinates',
  ),
  _Component('image', 'Apache-2.0', 'JPEG/PNG decode & encode'),
  _Component('xml', 'MIT', 'GPX/KML parsing'),
  _Component('http', 'BSD-3', 'Map tiles & geocoding'),
  _Component('archive', 'MIT / Apache', 'Takeout zip'),
  _Component(
    'file_selector · url_launcher · path_provider',
    'BSD / MIT',
    'File picking, links, app storage',
  ),
];

/// Opens the curated licenses page.
void showAppLicenses(BuildContext context) {
  Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const LicensesPage()));
}

/// Scrollable licenses screen.
class LicensesPage extends StatelessWidget {
  /// Creates the licenses page.
  const LicensesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Licenses')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('Stunda', style: text.headlineSmall),
          const SizedBox(height: 4),
          Text('Licensed under GPL-3.0-or-later', style: text.bodySmall),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: scheme.outline),
            ),
            child: SelectableText(
              _gpl,
              style: text.bodySmall?.copyWith(height: 1.5),
            ),
          ),
          const SizedBox(height: 24),
          Text('Attached software', style: text.titleLarge),
          const SizedBox(height: 4),
          Text(
            'The libraries and tools Stunda bundles or builds on — listed once '
            'each, by component.',
            style: text.bodySmall,
          ),
          const SizedBox(height: 12),
          for (final c in _attached)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.circle, size: 7, color: scheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(c.name, style: text.titleMedium),
                            ),
                            Text(
                              c.license,
                              style: text.bodySmall?.copyWith(
                                color: scheme.primary,
                              ),
                            ),
                          ],
                        ),
                        Text(c.role, style: text.bodySmall),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
