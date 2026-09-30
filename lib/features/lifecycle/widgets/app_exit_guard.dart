// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/services/lifecycle/app_exit_coordinator.dart';
import 'package:simcrux/services/lifecycle/app_exit_provider.dart';

/// Wraps the app so an OS-initiated termination drains in-flight
/// regressions before the process goes away.
///
/// The File → Quit action calls [AppExitCoordinator.shutdown] directly;
/// this widget covers the paths the app does not originate — closing
/// the last window, Cmd-Q / Alt-F4, and a session log-out. Those reach
/// Dart through [AppLifecycleListener.onExitRequested], which the
/// desktop embedders wire to their native "should terminate?" hook, so
/// returning [AppExitResponse.exit] only after the drain completes is
/// what actually holds the process open long enough to reap the
/// simulator trees.
///
/// The response is always [AppExitResponse.exit]: SimCrux never vetoes
/// a termination the user asked for. Cancelling in-flight runs is
/// cleanup, not a prompt.
class AppExitGuard extends ConsumerStatefulWidget {
  /// Creates an [AppExitGuard] around [child].
  const AppExitGuard({required this.child, super.key});

  /// The application subtree.
  final Widget child;

  @override
  ConsumerState<AppExitGuard> createState() => _AppExitGuardState();
}

class _AppExitGuardState extends ConsumerState<AppExitGuard> {
  AppLifecycleListener? _listener;

  @override
  void initState() {
    super.initState();
    _listener = AppLifecycleListener(onExitRequested: _onExitRequested);
  }

  Future<AppExitResponse> _onExitRequested() async {
    await ref.read(appExitCoordinatorProvider).shutdown();
    return AppExitResponse.exit;
  }

  @override
  void dispose() {
    _listener?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
