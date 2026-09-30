// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

/// Cancels one in-flight regression run. Completes once the run's
/// simulators have been signalled and reaped.
typedef ActiveRunCanceller = Future<void> Function();

/// Opaque handle returned by [ActiveRunRegistry.register].
class ActiveRunToken {
  /// Creates a token. Identity is the only thing that matters.
  ActiveRunToken();
}

/// App-scoped registry of the regression runs currently in flight.
///
/// Regression runs are started inside per-tab `ProviderContainer`s, so
/// no single notifier can see them all. This registry lives in the
/// root container (per [activeRunRegistryProvider]); each per-tab
/// runner registers while its run is live and unregisters when the run
/// reaches a terminal state. That gives the app-exit path — the one
/// caller that must act across every tab at once — a single place to
/// ask "what is still running?" and to cancel it.
///
/// Without this, quitting mid-regression left every in-flight
/// `vvp` / `verilator` / `make → python` process tree running, along
/// with its working directory: exactly the nightly-regression scenario
/// the process reaper exists to prevent.
class ActiveRunRegistry {
  final Map<ActiveRunToken, ActiveRunCanceller> _active =
      <ActiveRunToken, ActiveRunCanceller>{};

  /// Number of runs currently registered as in flight.
  int get activeCount => _active.length;

  /// True when at least one run is in flight.
  bool get hasActiveRuns => _active.isNotEmpty;

  /// Registers [cancel] as the canceller for a freshly-started run.
  /// Retain the returned token and pass it to [unregister] when the
  /// run reaches a terminal state.
  ActiveRunToken register(ActiveRunCanceller cancel) {
    final token = ActiveRunToken();
    _active[token] = cancel;
    return token;
  }

  /// Removes [token]'s run from the registry. Safe to call twice.
  void unregister(ActiveRunToken token) {
    _active.remove(token);
  }

  /// Cancels every registered run and waits for all of them, bounded
  /// by [grace].
  ///
  /// Returns true when every canceller completed within the budget,
  /// false when the budget expired first (the caller — app exit —
  /// proceeds either way; a hung driver must not wedge the quit).
  /// The registry is cleared regardless, so a second call is a no-op.
  ///
  /// Individual canceller failures are swallowed: one driver that
  /// throws on cancel must not prevent the others from being reaped.
  Future<bool> cancelAll({
    Duration grace = const Duration(seconds: 5),
  }) async {
    if (_active.isEmpty) return true;
    final cancellers = _active.values.toList();
    _active.clear();
    final futures = <Future<void>>[
      for (final cancel in cancellers)
        Future<void>(cancel).catchError((Object _) {}),
    ];
    try {
      await Future.wait(futures).timeout(grace);
      return true;
    } on TimeoutException {
      return false;
    }
  }
}
