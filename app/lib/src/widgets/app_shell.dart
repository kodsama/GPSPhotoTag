import 'package:flutter/material.dart';

import '../branding/logo_mark.dart';
import '../state/controller_scope.dart';
import '../theme/app_colors.dart';
import 'activity_log_panel.dart';
import 'walkthrough.dart';

/// The app frame: a header bar (logo, wordmark, theme toggle), the centred
/// scrollable walkthrough, a floating activity-log button with an unread badge,
/// and the right-side log slide-over.
class AppShell extends StatefulWidget {
  /// Creates the shell.
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  bool _logOpen = false;

  void _toggleLog() {
    setState(() => _logOpen = !_logOpen);
    if (_logOpen) ControllerScope.of(context).markLogRead();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    return Scaffold(
      body: Stack(
        children: [
          Column(
            children: [
              const _Header(),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 96),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: const Walkthrough(),
                    ),
                  ),
                ),
              ),
            ],
          ),
          ActivityLogPanel(
            visible: _logOpen,
            onClose: () => setState(() => _logOpen = false),
          ),
        ],
      ),
      floatingActionButton: _logOpen
          ? null
          : _LogButton(
              unread: controller.unreadCount,
              onPressed: _toggleLog,
            ),
    );
  }
}

/// The top header bar.
class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(bottom: BorderSide(color: scheme.outline)),
      ),
      child: Row(
        children: [
          const LogoMark(size: 34),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('GPSPhotoTag', style: text.headlineSmall),
                Text('Geotag your photos from GPX & Google location history',
                    style: text.bodySmall, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const SizedBox(width: 12),
          IconButton(
            tooltip: isDark ? 'Switch to light' : 'Switch to dark',
            icon: Icon(isDark ? Icons.light_mode : Icons.dark_mode),
            onPressed: controller.toggleTheme,
          ),
        ],
      ),
    );
  }
}

/// The floating activity-log button with an unread-count badge.
class _LogButton extends StatelessWidget {
  const _LogButton({required this.unread, required this.onPressed});

  final int unread;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        FloatingActionButton(
          onPressed: onPressed,
          tooltip: 'Activity log',
          child: const Icon(Icons.receipt_long),
        ),
        if (unread > 0)
          Positioned(
            right: -2,
            top: -2,
            child: Container(
              padding: const EdgeInsets.all(5),
              decoration: const BoxDecoration(
                color: AppColors.danger,
                shape: BoxShape.circle,
              ),
              constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
              alignment: Alignment.center,
              child: Text(
                unread > 99 ? '99+' : '$unread',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
