// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:simcrux/core/cli/flow_exit_code.dart';

/// Watches for SIGINT and SIGTERM while `simcrux flow run` runs, so a
/// cancelled CI job kills the run's process trees instead of stranding
/// them, and the binary re-exits with the conventional `128 + N`.
///
/// The SimCrux CLI had no signal handling before `flow`; LintCrux's Yosys
/// signal reaper is the precedent. SIGTERM cannot be watched on Windows, so
/// only SIGINT is watched there.
class FlowSignalReaper {
  /// Creates the reaper. [watch] is where signals come from,
  /// [ProcessSignal.watch] unless a test supplies its own: the handlers are
  /// process-wide, and a test that raised a real signal would race the test
  /// runner's own.
  FlowSignalReaper({
    Stream<ProcessSignal> Function(ProcessSignal signal)? watch,
  }) : _watch = watch ?? _watchProcess;

  static Stream<ProcessSignal> _watchProcess(ProcessSignal signal) =>
      signal.watch();

  final Stream<ProcessSignal> Function(ProcessSignal signal) _watch;
  final List<StreamSubscription<ProcessSignal>> _subscriptions =
      <StreamSubscription<ProcessSignal>>[];

  /// The exit code of the first signal handled, or null.
  int? get exitCode => _exitCode;
  int? _exitCode;

  /// The exit code a signal re-exits with.
  static int exitCodeFor(ProcessSignal signal) => signal == ProcessSignal.sigint
      ? FlowExitCode.sigint
      : FlowExitCode.sigterm;

  /// Starts watching. [onSignal] runs once, on the first signal: the caller
  /// cancels the run there, which kills its process trees.
  void install(void Function(ProcessSignal signal) onSignal) {
    final signals = <ProcessSignal>[
      ProcessSignal.sigint,
      if (!Platform.isWindows) ProcessSignal.sigterm,
    ];
    for (final signal in signals) {
      _subscriptions.add(
        _watch(signal).listen((s) {
          if (_exitCode != null) return;
          _exitCode = exitCodeFor(s);
          onSignal(s);
        }),
      );
    }
  }

  /// Stops watching. Idempotent.
  Future<void> dispose() async {
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
  }
}
