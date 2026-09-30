// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// The reaper-routing fake driver is intentionally fire-and-forget:
// `execute()` kicks off an async pump on a microtask while the scheduler
// consumes the stream. The cascade/discarded-future suppressions keep
// the per-test driver setup readable; both are by design here.
// ignore_for_file: cascade_invocations

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/kill_signal.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/resource_lock.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/job_scheduler/fake_process_runner.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/job_scheduler/process_reaper.dart';
import 'package:simcrux/services/simulator/ghdl_driver.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

import '../../support/poll_until.dart';

/// A minimal single-spawn [SimulatorDriver] that routes spawn + cancel
/// through the injected [ProcessReaper] (the production wiring), so the
/// scheduler + reaper escalation/tree control flow is exercised end to
/// end against the in-process [FakeProcessRunner] — no real simulator.
class _ReaperDriver implements SimulatorDriver {
  _ReaperDriver({
    required this.reaper,
    this.killGrace = const Duration(milliseconds: 20),
    this.throwForTestId,
  });

  final ProcessReaper reaper;
  final Duration killGrace;

  /// When set, `execute` for this test id throws synchronously before
  /// spawning (models a driver that dies mid-spawn).
  final String? throwForTestId;

  final Map<String, ReapableProcess> _live = <String, ReapableProcess>{};

  @override
  String get id => 'fake';

  @override
  String get displayName => 'Fake (reaper-routing)';

  @override
  SimulatorCapabilities get capabilities => SimulatorCapabilities(
    supportedLanguages: const {HdlLanguage.verilog},
    supportsVcd: false,
    supportsFst: false,
    supportsCocotb: false,
    requiresSeparateCompileStep: false,
    emitsStructuredOutput: false,
  );

  @override
  Future<String?> detectVersion(SimulatorBinaryConfig config) async => 'fake';

  @override
  Future<CompileResult> compile(CompileRequest request) async =>
      const CompileResult(
        success: true,
        artifactPath: 'noop',
        stdout: '',
        stderr: '',
      );

  @override
  Stream<TestExecutionEvent> execute(ExecuteRequest request) {
    final controller = StreamController<TestExecutionEvent>();
    unawaited(_run(request, controller));
    return controller.stream;
  }

  Future<void> _run(
    ExecuteRequest request,
    StreamController<TestExecutionEvent> controller,
  ) async {
    final startedAt = DateTime.now().toUtc();
    if (request.test.id == throwForTestId) {
      controller.addError(StateError('driver blew up mid-spawn'));
      await controller.close();
      return;
    }
    final process = await reaper.spawnGrouped(
      'sim',
      const <String>[],
      workingDirectory: request.workingDirectory,
    );
    _live[request.test.id] = process;
    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();
    final outSub = process.stdout.listen(
      (line) => controller.add(
        TestLogLine(line: line, fromStderr: false, timestamp: startedAt),
      ),
      onDone: stdoutDone.complete,
    );
    final errSub = process.stderr.listen(
      (line) => controller.add(
        TestLogLine(line: line, fromStderr: true, timestamp: startedAt),
      ),
      onDone: stderrDone.complete,
    );
    final exit = await process.exitCode;
    await Future.wait<void>([stdoutDone.future, stderrDone.future]);
    await outSub.cancel();
    await errSub.cancel();
    _live.remove(request.test.id);
    controller.add(
      TestExecutionFinished(
        status: exit == 0 ? TestStatus.pass : TestStatus.fail,
        exitCode: exit,
        startedAt: startedAt,
        finishedAt: DateTime.now().toUtc(),
        killSignal: process.killSignal,
      ),
    );
    await controller.close();
  }

  @override
  void cancel(String testId) {
    final process = _live[testId];
    if (process == null) return;
    unawaited(reaper.terminateTree(process, grace: killGrace));
  }
}

TestSpec _spec(
  String id, {
  String simulatorId = 'fake',
  Duration timeout = const Duration(seconds: 30),
  List<ResourceLock> resources = const <ResourceLock>[],
}) => TestSpec(
  id: id,
  name: id,
  suiteName: 'suite',
  simulatorId: simulatorId,
  top: 'tb',
  timeout: timeout,
  resources: resources,
);

RegressionConfig _config() => RegressionConfig(
  projectFilePath: '/fake/simcrux.yaml',
  schemaVersion: '1',
  suites: const [],
  simulatorBinaries: const {},
);

LocalJobScheduler _scheduler(SimulatorDriver driver, String runRoot) =>
    LocalJobScheduler(
      driverRegistry: SimulatorDriverRegistry({driver.id: driver}),
      config: _config(),
      runRoot: runRoot,
    );

/// Resolves a behaviour keyed by the safe test id, which the scheduler
/// encodes as the working directory's last path segment.
FakeProcessBehavior Function(FakeSpawnRequest) _byTestId(
  Map<String, FakeProcessBehavior> behaviors, {
  FakeProcessBehavior fallback = const FakeProcessBehavior(),
}) => (request) {
  final dir = request.workingDirectory;
  final key = dir == null ? '' : p.basename(dir);
  return behaviors[key] ?? fallback;
};

Future<List<TestResult>> _runAll(
  LocalJobScheduler scheduler,
  List<TestSpec> tests, {
  int concurrency = 4,
}) async {
  final events = await scheduler
      .submit(
        RegressionRequest(
          runId: 'r1',
          tests: tests,
          concurrency: concurrency,
        ),
      )
      .toList();
  return events.whereType<TestFinished>().map((e) => e.result).toList();
}

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('simcrux_reap_test_');
  });
  tearDown(() async {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  // 1. normalExit — exits 0 within timeout; reaper sends no signal.
  test('normalExit: passes, no kill signal, no live handles', () async {
    final fake = FakeProcessRunner();
    final scheduler = _scheduler(_ReaperDriver(reaper: fake), tmp.path);
    final results = await _runAll(scheduler, [_spec('alu_add')]);
    expect(results.single.status, TestStatus.pass);
    expect(results.single.killSignal, isNull);
    expect(fake.liveHandles, isEmpty);
  });

  // 2. timeoutGraceTerm — sleeps past timeout, exits on SIGTERM.
  test('timeoutGraceTerm: timed out, killSignal == SIGTERM', () async {
    final fake = FakeProcessRunner(
      resolveBehavior: _byTestId({'hang': FakeProcessBehavior.hang}),
    );
    final scheduler = _scheduler(_ReaperDriver(reaper: fake), tmp.path);
    final results = await _runAll(scheduler, [
      _spec('hang', timeout: const Duration(milliseconds: 40)),
    ]);
    expect(results.single.status, TestStatus.timeout);
    expect(results.single.killSignal, KillSignal.sigterm);
    expect(fake.liveHandles, isEmpty);
  });

  // 3. timeoutSigkillEscalation — ignores SIGTERM ⇒ SIGKILL escalation.
  // PRIMARY MUTATION TARGET: deleting the SIGKILL loop in
  // EscalatingProcessReaper.terminateTree makes this hang to the Timeout.
  test(
    'timeoutSigkillEscalation: ignores SIGTERM, killSignal == SIGKILL',
    () async {
      final fake = FakeProcessRunner(
        resolveBehavior: _byTestId({
          'stubborn': const FakeProcessBehavior(
            delay: Duration(days: 1),
            ignoresSigterm: true,
          ),
        }),
      );
      final scheduler = _scheduler(_ReaperDriver(reaper: fake), tmp.path);
      final results = await _runAll(scheduler, [
        _spec('stubborn', timeout: const Duration(milliseconds: 40)),
      ]);
      expect(results.single.status, TestStatus.timeout);
      expect(results.single.killSignal, KillSignal.sigkill);
      expect(fake.liveHandles, isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 8)),
  );

  // 4. cocotbGrandchildOrphan — parent forks 2 grandchildren that
  // outlive SIGTERM; a single-PID kill orphans them.
  // MUTATION TARGET: replacing treeMembers(handle) with [handle] leaves
  // the grandchildren in liveHandles.
  test('cocotbGrandchildOrphan: whole tree reaped, zero orphans', () async {
    final fake = FakeProcessRunner(
      resolveBehavior: _byTestId({
        'cocotb_tb': const FakeProcessBehavior(
          delay: Duration(days: 1),
          spawnsChildren: 2,
        ),
      }),
    );
    final scheduler = _scheduler(_ReaperDriver(reaper: fake), tmp.path);
    final results = await _runAll(scheduler, [
      _spec('cocotb_tb', timeout: const Duration(milliseconds: 40)),
    ]);
    expect(results.single.status, TestStatus.timeout);
    // The parent (make) honours SIGTERM, so the test's recorded terminal
    // signal is SIGTERM; the grandchildren ignore it and are reaped by
    // the whole-tree SIGKILL escalation that runs after the parent dies.
    expect(results.single.killSignal, KillSignal.sigterm);
    // The orphan invariant: no grandchild survives. Settles on the
    // grace-window timer. A single-PID kill (the mutation) never reaps
    // them, so this poll times out and the assertion below fails red.
    await pollUntil(() => fake.liveHandles.isEmpty);
    expect(fake.liveHandles, isEmpty, reason: 'no orphaned grandchildren');
  });

  // 5. zombieReaping — exited child is awaited; no handle lingers.
  test('zombieReaping: exited process leaves no live handle', () async {
    final fake = FakeProcessRunner(
      resolveBehavior: _byTestId({'quick': const FakeProcessBehavior()}),
    );
    final scheduler = _scheduler(_ReaperDriver(reaper: fake), tmp.path);
    final results = await _runAll(scheduler, [_spec('quick')]);
    expect(results.single.status, TestStatus.pass);
    expect(fake.liveHandles, isEmpty);
  });

  // 6. cancelMidflight — cancel reaps every in-flight handle; queued
  // tests never spawn.
  test('cancelMidflight: in-flight reaped, queued never spawn', () async {
    final fake = FakeProcessRunner(
      resolveBehavior: (_) => FakeProcessBehavior.hang,
    );
    final scheduler = _scheduler(
      _ReaperDriver(reaper: fake),
      tmp.path,
    );
    final tests = List.generate(6, (i) => _spec('t$i'));
    final events = <RegressionEvent>[];
    final done = Completer<void>();
    final sub = scheduler
        .submit(
          RegressionRequest(runId: 'r1', tests: tests, concurrency: 2),
        )
        .listen(events.add, onDone: done.complete);
    final started = await pollUntil(
      () => events.whereType<TestStarted>().length >= 2,
    );
    expect(started, isTrue, reason: 'expected 2 tests to start');
    await scheduler.cancel('r1');
    await done.future;
    await sub.cancel();
    expect(fake.liveHandles, isEmpty);
    // Concurrency 2 ⇒ at most 2 tests ever spawned before cancel.
    expect(fake.spawns.length, lessThanOrEqualTo(2));
    expect(events.last, isA<RegressionFinished>());
  });

  // 7. semaphoreReleaseOnThrow — a driver that throws mid-spawn still
  // releases its permit so the next queued test runs.
  test('semaphoreReleaseOnThrow: permit released, next test runs', () async {
    final fake = FakeProcessRunner();
    final scheduler = _scheduler(
      _ReaperDriver(reaper: fake, throwForTestId: 'boom'),
      tmp.path,
    );
    final results = await _runAll(
      scheduler,
      [_spec('boom'), _spec('ok')],
      concurrency: 1,
    );
    final byId = {for (final r in results) r.testId: r};
    expect(byId.keys, containsAll(<String>['boom', 'ok']));
    expect(byId['ok']!.status, TestStatus.pass);
  });

  // 8. resourceLockStarvation — 50 tests contend one lock; all run, and
  // the lock is released even when the holder times out.
  test(
    'resourceLockStarvation: all 50 run, lock released on timeout',
    () async {
      const lock = ResourceLock(name: 'fpga_board_0');
      final fake = FakeProcessRunner(
        resolveBehavior: _byTestId({'t0': FakeProcessBehavior.hang}),
      );
      final scheduler = _scheduler(
        _ReaperDriver(reaper: fake, killGrace: const Duration(milliseconds: 5)),
        tmp.path,
      );
      final tests = [
        // t0 holds the lock and times out; the rest must still acquire it.
        _spec(
          't0',
          timeout: const Duration(milliseconds: 30),
          resources: const [lock],
        ),
        for (var i = 1; i < 50; i++) _spec('t$i', resources: const [lock]),
      ];
      final results = await _runAll(scheduler, tests);
      expect(results, hasLength(50));
      expect(fake.liveHandles, isEmpty);
    },
  );

  // 9. multiStepCleanup — the real GHDL driver, fed a failing analyze
  // step, must not spawn elaborate / run.
  test('multiStepCleanup: failed analyze short-circuits later steps', () async {
    final fake = FakeProcessRunner(
      resolveBehavior: (request) {
        // GHDL analyze is `ghdl -a …`; fail it.
        if (request.args.contains('-a')) {
          return const FakeProcessBehavior(
            exitCode: 1,
            stderr: <String>['analyze error: syntax'],
          );
        }
        return const FakeProcessBehavior();
      },
    );
    final scheduler = _scheduler(GhdlDriver(reaper: fake), tmp.path);
    final results = await _runAll(scheduler, [
      _spec('vhdl', simulatorId: 'ghdl'),
    ]);
    expect(results.single.status, TestStatus.fail);
    // Only the analyze step spawned — no elaborate (`-e`) / run (`-r`).
    expect(fake.spawns, hasLength(1));
    expect(fake.spawns.single.args, contains('-a'));
    expect(
      fake.spawns.single.args,
      isNot(contains('-e')),
    );
  });

  // 10. doubleCancelIdempotent — cancelling twice signals once, no throw.
  test('doubleCancelIdempotent: two cancels, one terminal signal', () async {
    final fake = FakeProcessRunner(
      resolveBehavior: (_) => FakeProcessBehavior.hang,
    );
    final driver = _ReaperDriver(reaper: fake);
    final scheduler = _scheduler(driver, tmp.path);
    final events = <RegressionEvent>[];
    final done = Completer<void>();
    final sub = scheduler
        .submit(
          RegressionRequest(runId: 'r1', tests: [_spec('hang')]),
        )
        .listen(events.add, onDone: done.complete);
    final started = await pollUntil(
      () => events.whereType<TestStarted>().isNotEmpty,
    );
    expect(started, isTrue, reason: 'expected the test to start');
    // Two cancels in a row must not throw or double-signal.
    expect(() {
      driver.cancel('hang');
      driver.cancel('hang');
    }, returnsNormally);
    await scheduler.cancel('r1');
    await done.future;
    await sub.cancel();
    final result = events.whereType<TestFinished>().single.result;
    // The terminal signal is SIGTERM (honoured), recorded exactly once.
    expect(result.killSignal, KillSignal.sigterm);
    expect(fake.liveHandles, isEmpty);
  });

  // 11. cancelAfterComplete — cancelling a finished test is a no-op.
  test(
    'cancelAfterComplete: cancel after finish is a harmless no-op',
    () async {
      final fake = FakeProcessRunner(
        resolveBehavior: _byTestId({'quick': const FakeProcessBehavior()}),
      );
      final driver = _ReaperDriver(reaper: fake);
      final scheduler = _scheduler(driver, tmp.path);
      final results = await _runAll(scheduler, [_spec('quick')]);
      expect(results.single.status, TestStatus.pass);
      expect(results.single.killSignal, isNull);
      // Process already finished: cancel must not throw or signal a corpse.
      expect(() => driver.cancel('quick'), returnsNormally);
      expect(results.single.killSignal, isNull);
    },
  );

  // 12. killSignalUnsupportedPlatform — when SIGTERM never lands (the
  // Windows-no-op model), the run still ends bounded via SIGKILL.
  test(
    'killSignalUnsupportedPlatform: bounded termination via SIGKILL',
    () async {
      final fake = FakeProcessRunner(
        resolveBehavior: _byTestId({
          'winhang': const FakeProcessBehavior(
            delay: Duration(days: 1),
            ignoresSigterm: true,
          ),
        }),
      );
      final scheduler = _scheduler(
        _ReaperDriver(reaper: fake, killGrace: const Duration(milliseconds: 5)),
        tmp.path,
      );
      final results = await _runAll(scheduler, [
        _spec('winhang', timeout: const Duration(milliseconds: 30)),
      ]);
      expect(results.single.status, TestStatus.timeout);
      expect(results.single.killSignal, KillSignal.sigkill);
      expect(fake.liveHandles, isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 8)),
  );
}
