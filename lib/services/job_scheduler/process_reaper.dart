// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crux_io/crux_io.dart';
import 'package:simcrux/domain/enums/kill_signal.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart'
    show ProcessLauncher, ProcessStarter, TestProcess, defaultProcessLauncher;

/// A spawned process together with the descendant tree it may fork.
///
/// Extends [TestProcess] so drivers consume `stdout` / `stderr` /
/// `exitCode` exactly as before; the only addition is [killSignal],
/// which records the terminal signal the reaper delivered (or `null`
/// while the process has not been terminated by the reaper — it either
/// exited on its own or is still live).
abstract class ReapableProcess implements TestProcess {
  /// The terminal signal [ProcessReaper.terminateTree] delivered to this
  /// process tree, or `null` if the reaper never terminated it.
  KillSignal? get killSignal;
}

/// Spawns processes so their entire descendant tree can be reaped, and
/// terminates that tree under timeout / cancellation.
///
/// The compute hot loop (the actual HDL simulation) runs in a *child*
/// process the driver spawns; for Cocotb that child (`make`) itself
/// forks grandchildren (`python` → the wrapped simulator). Killing only
/// the parent PID orphans the grandchildren. The reaper exists to make
/// the kill target the whole **process tree**, not just the parent PID:
/// on POSIX by reaping the process group / descendant chain, on Windows
/// via `taskkill /T`.
///
/// Open-Core Extension Point: this seam lives in open-core so both the
/// open-core scheduler and the Pro overlay's plugin path reuse it. The
/// production default is the platform reaper ([processReaperProvider]);
/// unit tests inject a `FakeProcessRunner` (a faithful in-process model
/// of OS tree behaviour) so the vast majority of process-lifecycle
/// robustness tests need **no real simulator and no real OS process**.
abstract class ProcessReaper {
  /// Spawn [executable] with [args] such that [terminateTree] can later
  /// reap the whole descendant tree. [environment] / [workingDirectory]
  /// mirror `Process.start`.
  Future<ReapableProcess> spawnGrouped(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
    String? workingDirectory,
  });

  /// Terminate [handle]'s process tree: deliver `SIGTERM` to every tree
  /// member, then — if any member is still alive after [grace] —
  /// escalate to `SIGKILL`. Records the terminal signal on the handle's
  /// [ReapableProcess.killSignal]. Idempotent: a second call (or a call
  /// after the tree already exited) is a no-op.
  Future<void> terminateTree(
    ReapableProcess handle, {
    Duration grace = const Duration(seconds: 5),
  });
}

/// Internal mutable view of a [ReapableProcess] that the shared
/// [EscalatingProcessReaper] control flow stamps the kill signal onto.
/// Every concrete reaper's handle implements this.
abstract class MutableReapableProcess implements ReapableProcess {
  KillSignal? _killSignal;

  @override
  KillSignal? get killSignal => _killSignal;

  /// Records [signal] as the terminal signal delivered to this tree.
  // ignore: use_setters_to_change_properties
  void markKilledWith(KillSignal signal) => _killSignal = signal;
}

/// Shared SIGTERM → grace → SIGKILL escalation **and** whole-tree
/// control flow for every concrete reaper (real and fake).
///
/// This is the single production code path the process-lifecycle corpus
/// mutation-tests:
///
/// - Deleting the SIGKILL-escalation loop makes a process that ignores
///   SIGTERM hang past the grace window (the `timeoutSigkillEscalation`
///   case goes red — it hangs to the per-test timeout instead).
/// - Replacing `treeMembers(handle)` with `[handle]` reaps only the
///   parent PID, leaving grandchildren orphaned (the
///   `cocotbGrandchildOrphan` case goes red — surviving descendants).
///
/// Concrete reapers supply only the leaf operations
/// ([treeMembers] / [signalOne] / [isAlive]); the escalation policy
/// lives here once.
abstract class EscalatingProcessReaper implements ProcessReaper {
  @override
  Future<void> terminateTree(
    ReapableProcess handle, {
    Duration grace = const Duration(seconds: 5),
  }) async {
    final mutable = handle as MutableReapableProcess;
    // Idempotent: a tree already signalled is not signalled again.
    if (mutable.killSignal != null) return;
    final members = treeMembers(handle);
    // cancel-after-complete: nothing alive to signal.
    if (members.every((m) => !isAlive(m))) return;

    for (final member in members) {
      signalOne(member, KillSignal.sigterm);
    }
    mutable.markKilledWith(KillSignal.sigterm);

    // Always wait the grace window, then escalate only if a tree member
    // ignored SIGTERM and is still alive. The wait also covers the
    // asynchronous exit of a process that *did* honour SIGTERM, so a
    // graceful exit is never mis-escalated to SIGKILL.
    await Future<void>.delayed(grace);
    if (members.any(isAlive)) {
      for (final member in members) {
        signalOne(member, KillSignal.sigkill);
      }
      mutable.markKilledWith(KillSignal.sigkill);
    }
  }

  /// Every process in [handle]'s tree that must receive the signal.
  /// Real reapers return `[handle]` and reap descendants inside
  /// [signalOne] (via the OS process group / `taskkill /T`); the fake
  /// returns the parent plus its modelled grandchildren so the orphan
  /// invariant is observable without an OS.
  List<ReapableProcess> treeMembers(ReapableProcess handle);

  /// Deliver [signal] to one tree [member] (and, for real reapers, its
  /// OS descendants).
  void signalOne(ReapableProcess member, KillSignal signal);

  /// Whether [member]'s process is still alive.
  bool isAlive(ReapableProcess member);
}

/// Maps a domain [KillSignal] to the `dart:io` [ProcessSignal].
ProcessSignal processSignalFor(KillSignal signal) => switch (signal) {
  KillSignal.sigterm => ProcessSignal.sigterm,
  KillSignal.sigkill => ProcessSignal.sigkill,
};

/// The current behaviour, preserved: single-process spawn (no grouping)
/// with SIGTERM → grace → SIGKILL on the lone PID.
///
/// Used as the drivers' default reaper so existing behaviour and the
/// existing driver test suites are unchanged, and as the documented
/// fallback on platforms where neither the POSIX nor the Windows
/// strategy applies. Spawns through a [ProcessLauncher] so tests that
/// already inject a launcher keep working untouched.
class NoopProcessReaper extends EscalatingProcessReaper {
  /// Creates a [NoopProcessReaper] spawning via [launcher] (defaults to
  /// the `dart:io`-backed [defaultProcessLauncher]).
  NoopProcessReaper({ProcessLauncher? launcher})
    : _launcher = launcher ?? defaultProcessLauncher;

  final ProcessLauncher _launcher;

  @override
  Future<ReapableProcess> spawnGrouped(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
    String? workingDirectory,
  }) async {
    final process = await _launcher(
      executable,
      args,
      environment: environment,
      workingDirectory: workingDirectory,
    );
    return _LauncherReapable(process);
  }

  @override
  List<ReapableProcess> treeMembers(ReapableProcess handle) =>
      <ReapableProcess>[handle];

  @override
  void signalOne(ReapableProcess member, KillSignal signal) {
    (member as _LauncherReapable)._inner.kill(processSignalFor(signal));
  }

  @override
  bool isAlive(ReapableProcess member) =>
      !(member as _LauncherReapable)._exited;
}

/// [ReapableProcess] adapter over a launcher-produced [TestProcess].
class _LauncherReapable extends MutableReapableProcess {
  _LauncherReapable(this._inner);

  final TestProcess _inner;
  bool _exited = false;
  Future<int>? _exitFuture;

  @override
  Stream<String> get stdout => _inner.stdout;

  @override
  Stream<String> get stderr => _inner.stderr;

  // Memoized so the underlying exit is observed lazily on first access
  // (preserving the driver's "subscribe to stdout, then await exit"
  // ordering) and self-exit is tracked for [NoopProcessReaper.isAlive].
  @override
  Future<int> get exitCode => _exitFuture ??= _inner.exitCode.then((code) {
    _exited = true;
    return code;
  });

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) =>
      _inner.kill(signal);
}

/// POSIX reaper: kills the whole descendant chain.
///
/// Best-effort and exercised only by the real-simulator integration
/// tests (which skip when the simulator binary is absent) — the
/// unit-level robustness sweep runs against the in-process
/// `FakeProcessRunner`. On terminate it walks descendants via `pgrep -P`
/// (present on Linux and macOS) depth-first and signals each PID, so a
/// Cocotb `make → python → vvp` chain is reaped rather than orphaned.
/// Dart cannot `setpgid` a child, so descendant discovery — not a
/// negative-PGID signal — is the portable, footgun-free strategy.
class PosixProcessGroupReaper extends EscalatingProcessReaper {
  @override
  Future<ReapableProcess> spawnGrouped(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
    String? workingDirectory,
  }) async {
    final process = await Process.start(
      executable,
      args,
      environment: environment,
      workingDirectory: workingDirectory,
    );
    return _OsReapable(process);
  }

  @override
  List<ReapableProcess> treeMembers(ReapableProcess handle) =>
      <ReapableProcess>[handle];

  @override
  void signalOne(ReapableProcess member, KillSignal signal) {
    _killTree((member as _OsReapable)._process.pid, processSignalFor(signal));
  }

  @override
  bool isAlive(ReapableProcess member) => !(member as _OsReapable)._exited;

  void _killTree(int pid, ProcessSignal signal) {
    try {
      final probe = Process.runSync('pgrep', <String>['-P', '$pid']);
      if (probe.exitCode == 0) {
        for (final line in (probe.stdout as String).split('\n')) {
          final child = int.tryParse(line.trim());
          if (child != null) _killTree(child, signal);
        }
      }
    } on Object {
      // pgrep absent / unusable: fall through to the direct kill.
    }
    Process.killPid(pid, signal);
  }
}

/// Windows reaper: `taskkill /T` reaps the child and its descendants.
///
/// Both of its spawns, the engine and `taskkill`, resolve the executable
/// through `crux_io` first ([SpawnHost.requireExecutable]): `CreateProcess`
/// searches the directory SimCrux was launched from before `PATH`, and that
/// is usually the repository whose tests are running, so a same-named binary
/// committed there would otherwise run. An engine found nowhere throws the
/// `ProcessException` a missing binary throws, which the drivers report as
/// "not available"; a `taskkill` found nowhere falls back to the direct kill.
///
/// The tree reaping itself is best-effort and integration-tested only (see
/// [PosixProcessGroupReaper]). [host], [start] and [runSync] default to the
/// live process and exist so the resolution can be tested on any machine.
class WindowsJobObjectReaper extends EscalatingProcessReaper {
  /// Creates a [WindowsJobObjectReaper].
  WindowsJobObjectReaper({
    this.host,
    this.start = Process.start,
    this.runSync = _defaultRunSync,
  });

  /// The host facts executables are resolved against; null means the live
  /// process.
  final SpawnHost? host;

  /// Starts the engine process.
  final ProcessStarter start;

  /// Runs `taskkill` to completion.
  final ProcessResult Function(String executable, List<String> args) runSync;

  static ProcessResult _defaultRunSync(String executable, List<String> args) =>
      Process.runSync(executable, args);

  SpawnHost get _liveHost => host ?? SpawnHost.current();

  @override
  Future<ReapableProcess> spawnGrouped(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
    String? workingDirectory,
  }) async {
    final process = await start(
      _liveHost.requireExecutable(executable, childEnvironment: environment),
      args,
      environment: environment,
      workingDirectory: workingDirectory,
    );
    return _OsReapable(process);
  }

  @override
  List<ReapableProcess> treeMembers(ReapableProcess handle) =>
      <ReapableProcess>[handle];

  @override
  void signalOne(ReapableProcess member, KillSignal signal) {
    final pid = (member as _OsReapable)._process.pid;
    final args = <String>[
      if (signal == KillSignal.sigkill) '/F',
      '/T',
      '/PID',
      '$pid',
    ];
    try {
      runSync(_liveHost.requireExecutable('taskkill'), args);
    } on Object {
      // taskkill unavailable, or not on PATH: best-effort direct kill. Never
      // retried by bare name, which is the search the resolution prevents.
      member.kill(processSignalFor(signal));
    }
  }

  @override
  bool isAlive(ReapableProcess member) => !(member as _OsReapable)._exited;
}

/// [ReapableProcess] over a real `dart:io` [Process] (carries a PID for
/// the OS reapers).
class _OsReapable extends MutableReapableProcess {
  _OsReapable(this._process) {
    unawaited(_process.exitCode.then((_) => _exited = true));
  }

  final Process _process;
  bool _exited = false;

  @override
  Stream<String> get stdout => _process.stdout
      .transform(const SystemEncoding().decoder)
      .transform(const LineSplitter());

  @override
  Stream<String> get stderr => _process.stderr
      .transform(const SystemEncoding().decoder)
      .transform(const LineSplitter());

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) =>
      _process.kill(signal);
}

/// The platform-appropriate production reaper.
///
/// Kept free of any Flutter / Riverpod dependency so the corpus
/// generator (`tool/generate_orchestration_fixtures.dart`) and the soak
/// harness can replay scenarios under a plain `dart run`. The Riverpod
/// [processReaperProvider] (in `process_reaper_provider.dart`) wraps this.
ProcessReaper defaultProcessReaper() {
  if (Platform.isWindows) return WindowsJobObjectReaper();
  if (Platform.isLinux || Platform.isMacOS) {
    return PosixProcessGroupReaper();
  }
  // Unknown/unsupported platform: degrade to single-PID behaviour.
  return NoopProcessReaper();
}
