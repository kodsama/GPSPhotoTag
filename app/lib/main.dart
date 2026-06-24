import 'package:flutter/material.dart';

import 'src/state/app_controller.dart';
import 'src/state/controller_scope.dart';
import 'src/theme/app_theme.dart';
import 'src/widgets/app_shell.dart';

void main() => runApp(const GpsPhotoTagApp());

/// Root of the GPSPhotoTag desktop GUI.
///
/// Owns the single [AppController], publishes it to the tree via
/// [ControllerScope], and rebuilds [MaterialApp] when the theme mode changes.
class GpsPhotoTagApp extends StatefulWidget {
  /// Creates the app, optionally with an injected [controller] (tests).
  const GpsPhotoTagApp({super.key, this.controller});

  /// The controller to use; a fresh one is created when null.
  final AppController? controller;

  @override
  State<GpsPhotoTagApp> createState() => _GpsPhotoTagAppState();
}

class _GpsPhotoTagAppState extends State<GpsPhotoTagApp> {
  late final AppController _controller =
      widget.controller ?? AppController();

  @override
  void dispose() {
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ControllerScope(
      controller: _controller,
      child: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) => MaterialApp(
          title: 'GPSPhotoTag',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: _controller.themeMode,
          home: const AppShell(),
        ),
      ),
    );
  }
}
