import 'package:flutter/material.dart';

import 'app_controller.dart';

/// Exposes the [AppController] to the widget tree without the `provider`
/// package, rebuilding dependents when the controller notifies.
class ControllerScope extends InheritedNotifier<AppController> {
  /// Wraps [child], making [controller] available via [ControllerScope.of].
  const ControllerScope({
    super.key,
    required AppController controller,
    required super.child,
  }) : super(notifier: controller);

  /// The nearest [AppController]; throws if none is in scope.
  static AppController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ControllerScope>();
    assert(scope != null, 'No ControllerScope found in context');
    return scope!.notifier!;
  }
}
