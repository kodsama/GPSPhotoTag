import 'package:flutter/material.dart';

import '../branding/logo_mark.dart';
import '../screens/action_screen.dart';
import '../screens/explore_map_screen.dart';
import '../screens/scanning_screen.dart';
import '../screens/welcome_screen.dart';
import '../screens/workspace_screen.dart';
import '../state/app_controller.dart';
import '../state/app_screen.dart';
import '../state/controller_scope.dart';
import '../theme/app_colors.dart';
import 'activity_log_panel.dart';
import 'app_background.dart';
import 'glass.dart';
import 'licenses.dart';
import 'settings_dialog.dart';
import 'warning_banner.dart';

/// The app frame: a header bar (logo, wordmark, MCP chip, theme toggle), the
/// active screen (welcome → scanning → workspace ⇄ action), a floating
/// activity-log button with an unread badge, and the right-side log slide-over.
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
    // The header belongs only to the main pages; sub-pages carry their own
    // back affordance (a "Library" button), so it would only be redundant.
    final showHeader =
        controller.screen == AppScreen.welcome ||
        controller.screen == AppScreen.workspace;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          AppBackground(
            imagePath: controller.backgroundImagePath,
            veil: controller.backgroundVeil,
          ),
          Column(
            children: [
              if (showHeader) const _Header(),
              const WarningBanner(),
              const Expanded(child: _ScreenBody()),
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
          : _LogButton(unread: controller.unreadCount, onPressed: _toggleLog),
    );
  }
}

/// Renders the screen for the controller's current [AppScreen].
class _ScreenBody extends StatelessWidget {
  const _ScreenBody();

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    // The Explore map fills the available height itself (it must not live in a
    // scroll view); every other screen scrolls inside the standard padding.
    if (controller.screen == AppScreen.explore) {
      return const ExploreMapScreen();
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 96),
      child: switch (controller.screen) {
        AppScreen.welcome => const WelcomeScreen(),
        AppScreen.scanning => const ScanningScreen(),
        AppScreen.workspace => const WorkspaceScreen(),
        AppScreen.action => const ActionScreen(),
        AppScreen.explore => const SizedBox.shrink(),
      },
    );
  }
}

/// The top header bar.
class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    final text = Theme.of(context).textTheme;
    return GlassSurface(
      borderRadius: BorderRadius.zero,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Row(
        children: [
          const LogoMark(size: 34),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Stunda', style: text.headlineSmall),
                Text(
                  'Give every photo its moment',
                  style: text.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          _SettingsMenu(controller: controller),
        ],
      ),
    );
  }
}

/// Top-right overflow menu: appearance toggle, settings, licenses, and about.
class _SettingsMenu extends StatelessWidget {
  const _SettingsMenu({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return PopupMenuButton<String>(
      tooltip: 'Menu',
      icon: const Icon(Icons.settings),
      position: PopupMenuPosition.under,
      onSelected: (v) {
        switch (v) {
          case 'theme':
            controller.setDark(!isDark);
          case 'settings':
            showSettingsDialog(context, controller);
          case 'licenses':
            showAppLicenses(context);
          case 'about':
            _showAbout(context);
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'theme',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(isDark ? Icons.light_mode : Icons.dark_mode),
            title: Text(isDark ? 'Appearance: Light' : 'Appearance: Dark'),
          ),
        ),
        const PopupMenuItem(
          value: 'settings',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.tune),
            title: Text('Settings…'),
          ),
        ),
        const PopupMenuItem(
          value: 'licenses',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.gavel),
            title: Text('Licenses'),
          ),
        ),
        const PopupMenuItem(
          value: 'about',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.info_outline),
            title: Text('About'),
          ),
        ),
      ],
    );
  }
}

/// Shows the About dialog: the logo mark, version, tagline, author, license.
void _showAbout(BuildContext context) {
  showAboutDialog(
    context: context,
    applicationName: 'Stunda',
    applicationVersion: '2.0.0',
    applicationIcon: const LogoMark(size: 48),
    applicationLegalese:
        'Give every photo its moment.\n'
        'Author: Kodsama\n'
        'GPL-3.0-or-later',
  );
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
