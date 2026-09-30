// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:simcrux/domain/enums/kill_signal.dart';
import 'package:simcrux/services/job_scheduler/process_reaper.dart';

/// One spawn request the [FakeProcessRunner] observed. Recorded so tests
/// can assert *which* processes a driver spawned (e.g. that a failed
/// middle compile step short-circuits later steps).
class FakeSpawnRequest {
  /// Creates a [FakeSpawnRequest].
  FakeSpawnRequest({
    required this.executable,
    required this.args,
    required this.environment,
    required this.workingDirectory,
  });

  /// The executable the driver asked to spawn.
  final String executable;

  /// The argument vector.
  final List<String> args;

  /// The environment overlay, if any.
  final Map<String, String>? environment;

  /// The working directory (the scheduler encodes the safe test id as
  /// its last path segment).
  final String? workingDirectory;
}

/// The deterministic behaviour the fake replays for one spawned process
/// — the in-memory analogue of a `behaviors.json` entry.
class FakeProcessBehavior {
  /// Creates a [FakeProcessBehavior].
  const FakeProcessBehavior({
    this.exitCode = 0,
    this.stdout = const <String>[],
    this.stderr = const <String>[],
    this.delay = const Duration(milliseconds: 1),
    this.ignoresSigterm = false,
    this.spawnsChildren = 0,
  });

  /// A process that never exits on its own (until killed). Used for
  /// hang / timeout scenarios.
  static const FakeProcessBehavior hang = FakeProcessBehavior(
    delay: Duration(days: 1),
  );

  /// Exit code reported when the process exits on its own.
  final int exitCode;

  /// Scripted stdout lines (emitted before the terminal exit).
  final List<String> stdout;

  /// Scripted stderr lines.
  final List<String> stderr;

  /// How long the process runs before exiting on its own. A large value
  /// models a hang that only the reaper can end.
  final Duration delay;

  /// When true, the process ignores `SIGTERM` and only dies on the
  /// escalated `SIGKILL` — forcing the grace-window escalation path.
  final bool ignoresSigterm;

  /// Number of grandchildren the process forks (e.g. Cocotb's
  /// `make → python → vvp`). The grandchildren outlive `SIGTERM` and
  /// are only reaped when the whole tree is signalled, so a single-PID
  /// kill orphans them.
  final int spawnsChildren;
}

/// A faithful in-process model of an OS process tree, implementing the
/// open-core [ProcessReaper] contract with **no real OS process**.
///
/// This is the spine of the SimCrux orchestration-robustness suite: it
/// lets the process-lifecycle, timeout, cancellation and tree-reaping
/// invariants run in milliseconds on every platform, with no simulator
/// installed. The real-simulator integration tests
/// (`test/integration/`) remain the end-to-end backbone and skip when
/// the binary is absent.
///
/// It extends [EscalatingProcessReaper], so it shares the *exact* same
/// SIGTERM → grace → SIGKILL escalation and whole-tree control flow as
/// the production reapers; only the leaf operations differ (flip an
/// in-memory flag instead of signalling the OS). That shared control
/// flow is what the robustness corpus mutation-tests.
class FakeProcessRunner extends EscalatingProcessReaper {
  /// Creates a [FakeProcessRunner].
  ///
  /// [resolveBehavior] picks the behaviour for each spawn; the default
  /// is an instant clean exit. A driver with a separate compile step
  /// spawns more than once per test — resolvers typically return a fast
  /// success for compile-stage executables and the scenario behaviour
  /// for the run stage.
  FakeProcessRunner({
    FakeProcessBehavior Function(FakeSpawnRequest request)? resolveBehavior,
  }) : _resolveBehavior = resolveBehavior ?? _defaultBehavior;

  static FakeProcessBehavior _defaultBehavior(FakeSpawnRequest _) =>
      const FakeProcessBehavior();

  final FakeProcessBehavior Function(FakeSpawnRequest request) _resolveBehavior;

  /// Every spawn the fake observed, in call order.
  final List<FakeSpawnRequest> spawns = <FakeSpawnRequest>[];

  final Set<_FakeReapable> _live = <_FakeReapable>{};

  /// Every process (parent or grandchild) currently alive. A correct
  /// tree reap leaves this empty; an orphaned grandchild lingers here.
  Set<ReapableProcess> get liveHandles =>
      Set<ReapableProcess>.unmodifiable(_live);

  @override
  Future<ReapableProcess> spawnGrouped(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
    String? workingDirectory,
  }) async {
    final request = FakeSpawnRequest(
      executable: executable,
      args: List<String>.unmodifiable(args),
      environment: environment,
      workingDirectory: workingDirectory,
    );
    spawns.add(request);
    final behavior = _resolveBehavior(request);

    final children = <_FakeReapable>[
      for (var i = 0; i < behavior.spawnsChildren; i++)
        // Grandchildren outlive SIGTERM (they must be reaped via the
        // whole-tree kill); model that with ignoresSigterm + no self
        // exit.
        _FakeReapable(
          behavior: const FakeProcessBehavior(
            ignoresSigterm: true,
            delay: Duration(days: 1),
          ),
          onExit: _onExit,
        ),
    ];
    final parent = _FakeReapable(
      behavior: behavior,
      onExit: _onExit,
      children: children,
    );
    _live
      ..add(parent)
      ..addAll(children);
    parent.start();
    return parent;
  }

  void _onExit(_FakeReapable handle) => _live.remove(handle);

  @override
  List<ReapableProcess> treeMembers(ReapableProcess handle) {
    final parent = handle as _FakeReapable;
    return <ReapableProcess>[parent, ...parent.children];
  }

  @override
  void signalOne(ReapableProcess member, KillSignal signal) {
    final handle = member as _FakeReapable;
    if (!_live.contains(handle)) return;
    if (signal == KillSignal.sigterm && handle.behavior.ignoresSigterm) {
      // Honour the model: SIGTERM is swallowed; the process stays alive
      // until the escalated SIGKILL.
      return;
    }
    handle.killWith(signal);
  }

  @override
  bool isAlive(ReapableProcess member) => _live.contains(member);
}

/// One modelled process (parent or grandchild).
class _FakeReapable extends MutableReapableProcess {
  _FakeReapable({
    required this.behavior,
    required void Function(_FakeReapable handle) onExit,
    this.children = const <_FakeReapable>[],
    // Named parameters cannot be private, so the public-named `onExit`
    // cannot be an initializing formal for the private `_onExit` field.
    // ignore: prefer_initializing_formals
  }) : _onExit = onExit;

  final FakeProcessBehavior behavior;
  final List<_FakeReapable> children;
  final void Function(_FakeReapable handle) _onExit;

  final StreamController<String> _stdout = StreamController<String>();
  final StreamController<String> _stderr = StreamController<String>();
  final Completer<int> _exit = Completer<int>();
  Timer? _selfExitTimer;
  var _terminated = false;

  /// Begins the scripted timeline: emit log lines, then schedule the
  /// self-exit (unless killed first).
  void start() {
    behavior.stdout.forEach(_stdout.add);
    behavior.stderr.forEach(_stderr.add);
    _selfExitTimer = Timer(behavior.delay, () {
      if (_terminated) return;
      // A process that finishes its job on its own also ends its
      // grandchildren (they completed first — that is why the parent
      // returned). Cascade their exit.
      _finish(behavior.exitCode, cascade: true);
    });
  }

  /// Reaps this process with [signal] (driven by the reaper's escalation
  /// control flow). A kill does **not** cascade to grandchildren: that is
  /// the whole orphan hazard — killing only the parent PID leaves the
  /// grandchildren running until they are signalled in their own right.
  void killWith(KillSignal signal) {
    if (_terminated) return;
    _finish(signal == KillSignal.sigkill ? -9 : -15, cascade: false);
  }

  void _finish(int code, {required bool cascade}) {
    if (_terminated) return;
    _terminated = true;
    _selfExitTimer?.cancel();
    _onExit(this);
    if (cascade) {
      for (final child in children) {
        child._finish(code, cascade: true);
      }
    }
    unawaited(_stdout.close());
    unawaited(_stderr.close());
    if (!_exit.isCompleted) _exit.complete(code);
  }

  @override
  Stream<String> get stdout => _stdout.stream;

  @override
  Stream<String> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killWith(
      signal == ProcessSignal.sigkill ? KillSignal.sigkill : KillSignal.sigterm,
    );
    return true;
  }
}
