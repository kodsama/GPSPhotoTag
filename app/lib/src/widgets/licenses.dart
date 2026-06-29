/// A curated licenses page: Stunda's own license plus the notable attached
/// software (one entry per component — not the per-package/per-file dump that
/// Flutter's default license page produces).
library;

import 'package:flutter/material.dart';

import '../i18n/app_localizations.dart';

/// One attached component (listed once, by component).
class _Component {
  const _Component(this.name, this.license, this.roleKey);

  /// Component name (a proper noun/package name; not localized).
  final String name;

  /// License identifier(s) (SPDX-style; not localized).
  final String license;

  /// Localization key for what the component does for Stunda.
  final String roleKey;
}

const _attached = <_Component>[
  _Component('ExifTool', 'Artistic / GPL', 'lic_role_exiftool'),
  _Component('Flutter & Dart', 'BSD-3-Clause', 'lic_role_flutter'),
  _Component(
    'flutter_map + OpenStreetMap tiles',
    'BSD-3 / © OpenStreetMap contributors',
    'lic_role_map',
  ),
  _Component(
    'flutter_map_marker_cluster + latlong2',
    'MIT / BSD',
    'lic_role_cluster',
  ),
  _Component('image', 'Apache-2.0', 'lic_role_image'),
  _Component('ONNX Runtime', 'MIT', 'lic_role_onnxruntime'),
  _Component(
    'SSD-MobileNet v1 (ONNX Model Zoo)',
    'Apache-2.0',
    'lic_role_ssd_mobilenet',
  ),
  _Component(
    'MobileNetV2 (ONNX Model Zoo)',
    'Apache-2.0',
    'lic_role_mobilenet_embed',
  ),
  _Component('xml', 'MIT', 'lic_role_xml'),
  _Component('http', 'BSD-3', 'lic_role_http'),
  _Component('archive', 'MIT / Apache', 'lic_role_archive'),
  _Component(
    'file_selector · url_launcher · path_provider',
    'BSD / MIT',
    'lic_role_files',
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
      appBar: AppBar(title: Text(context.tr('licenses_title'))),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(context.tr('licenses_app_name'), style: text.headlineSmall),
          const SizedBox(height: 4),
          Text(context.tr('licenses_app_license'), style: text.bodySmall),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: scheme.outline),
            ),
            child: SelectableText(
              context.tr('licenses_gpl'),
              style: text.bodySmall?.copyWith(height: 1.5),
            ),
          ),
          const SizedBox(height: 24),
          Text(context.tr('licenses_attached'), style: text.titleLarge),
          const SizedBox(height: 4),
          Text(context.tr('licenses_attached_desc'), style: text.bodySmall),
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
                        Text(context.tr(c.roleKey), style: text.bodySmall),
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
