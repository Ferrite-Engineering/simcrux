// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:simcrux/services/lifecycle/active_run_registry.dart';

/// Terminates the host process with [code]. Injected so tests can
/// observe the exit decision without killing the test runner.
typedef ProcessExitCallback = void Function(int code);

/// Orchestrates an orderly application shutdown.
///
/// Both user-visible quit paths route through [shutdown]:
///
/// * the File → Quit action (`SimcruxAction.quit`), and
/// * an OS-initiated termination (window close, Cmd-Q, log-out),
///   which reaches Dart via `AppLifecycleListener.onExitRequested`.
///
/// Shutting down means cancelling every in-flight regression through
/// the [ActiveRunRegistry] — each cancellation routes into the
/// scheduler, which signals its drivers, which reap their process
/// trees (SIGTERM → grace → SIGKILL) — and waiting for that to settle
/// under a bounded budget. The budget matters: a wedged simulator must
/// delay the quit, never block it.
class AppExitCoordinator {
  /// Creates a coordinator over [registry].
  AppExitCoordinator({
    required this.registry,
    this.grace = kDefaultShutdownGrace,
  });

  /// Time budget for cancelling in-flight runs during shutdown.
  ///
  /// Comfortably longer than the process reaper's own SIGTERM→SIGKILL
  /// grace (5 s) so a well-behaved reap completes inside the budget,
  /// and short enough that a hung driver does not leave the user
  /// staring at an unresponsive window.
  static const Duration kDefaultShutdownGrace = Duration(seconds: 8);

  /// Registry of in-flight runs, consulted and drained by [shutdown].
  final ActiveRunRegistry registry;

  /// Budget handed to [ActiveRunRegistry.cancelAll].
  final Duration grace;

  Future<bool>? _shutdown;

  /// True once [shutdown] has been entered. Lets the exit-request
  /// handler recognize a second OS termination request instead of
  /// queueing another drain.
  bool get isShuttingDown => _shutdown != null;

  /// Cancels every in-flight regression and waits, bounded by [grace].
  ///
  /// Returns true when everything settled inside the budget. Idempotent
  /// — a re-entrant quit (a second OS termination request, or Cmd-Q
  /// racing the File → Quit action) awaits the **same** in-flight drain
  /// rather than returning immediately. Returning true early let the
  /// caller `exit(0)` before the first drain's cancellers had reaped
  /// anything, orphaning in-flight simulators — the exact leak shutdown
  /// exists to prevent.
  Future<bool> shutdown() => _shutdown ??= registry.cancelAll(grace: grace);
}
