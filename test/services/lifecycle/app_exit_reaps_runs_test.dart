// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// The scripted-driver lifecycle is fire-and-forget by design:
// `script.start()` runs on a microtask while the scheduler consumes the
// stream it produces.
// ignore_for_file: discarded_futures

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/lifecycle/active_run_registry.dart';
import 'package:simcrux/services/lifecycle/app_exit_coordinator.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

/// A scripted process that runs until something kills it. Records
/// whether it was killed so the exit path can be asserted against
/// "the simulator actually died", not merely "cancel() was called".
class _ScriptedProcess {
  _ScriptedProcess(this.testId);

  final String testId;
  final StreamController<TestExecutionEvent> controller =
      StreamController<TestExecutionEvent>();

  bool killed = false;
  final Completer<void> _killed = Completer<void>();

  Future<void> run() async {
    final startedAt = DateTime.now().toUtc();
    controller.add(
      TestLogLine(
        line: 'simulation started',
        fromStderr: false,
        timestamp: startedAt,
      ),
    );
    // Runs forever until reaped — the long nightly-regression case.
    await _killed.future;
    controller.add(
      TestExecutionFinished(
        status: TestStatus.cancelled,
        exitCode: -15,
        startedAt: startedAt,
        finishedAt: DateTime.now().toUtc(),
      ),
    );
    await controller.close();
  }

  void kill() {
    if (killed) return;
    killed = true;
    _killed.complete();
  }
}

class _ReapableFakeDriver implements SimulatorDriver {
  final Map<String, _ScriptedProcess> processes = <String, _ScriptedProcess>{};

  @override
  String get id => 'fake';

  @override
  String get displayName => 'Fake';

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
    final process = _ScriptedProcess(request.test.id);
    processes[request.test.id] = process;
    process.run();
    return process.controller.stream;
  }

  @override
  void cancel(String testId) {
    // Stands in for ProcessReaper.terminateTree: SIGTERM → grace →
    // SIGKILL across the process tree.
    processes[testId]?.kill();
  }
}

/// A driver whose compile stage blocks until reaped — the long
/// Verilator/GHDL compile. Records whether its compile process was
/// killed so the exit path can assert the compile stage (not just
/// execute) is reachable by cancel. execute() is never reached in the
/// compile-cancel scenario.
class _CompileBlockingDriver implements SimulatorDriver {
  final Map<String, Completer<void>> _compileKilled =
      <String, Completer<void>>{};
  final Set<String> compiledIds = <String>{};
  bool executeReached = false;

  Completer<void> _killerFor(String id) =>
      _compileKilled.putIfAbsent(id, Completer<void>.new);

  /// True once every started compile has been reaped.
  bool get allCompilesKilled =>
      _compileKilled.isNotEmpty &&
      _compileKilled.values.every((c) => c.isCompleted);

  @override
  String get id => 'fake';

  @override
  String get displayName => 'Fake';

  @override
  SimulatorCapabilities get capabilities => SimulatorCapabilities(
    supportedLanguages: const {HdlLanguage.verilog},
    supportsVcd: false,
    supportsFst: false,
    supportsCocotb: false,
    // The distinguishing capability: this driver has a separate compile
    // step, so the scheduler routes through the compile stage first.
    requiresSeparateCompileStep: true,
    emitsStructuredOutput: false,
  );

  @override
  Future<String?> detectVersion(SimulatorBinaryConfig config) async => 'fake';

  @override
  Future<CompileResult> compile(CompileRequest request) async {
    final id = request.test.id;
    compiledIds.add(id);
    // Block until cancel() reaps this compile — the runaway compiler.
    await _killerFor(id).future;
    return const CompileResult(
      success: false,
      artifactPath: null,
      stdout: '',
      stderr: 'compile cancelled',
    );
  }

  @override
  Stream<TestExecutionEvent> execute(ExecuteRequest request) {
    executeReached = true;
    // Should never be reached in the compile-cancel scenario.
    return const Stream<TestExecutionEvent>.empty();
  }

  @override
  void cancel(String testId) {
    final killer = _compileKilled[testId];
    if (killer != null && !killer.isCompleted) killer.complete();
  }
}

TestSpec _spec(String id) => TestSpec(
  id: id,
  name: id,
  suiteName: 'suite',
  simulatorId: 'fake',
  top: 'tb',
);

void main() {
  group('app exit reaps in-flight regressions', () {
    test(
      'shutdown kills every running simulator across every registered run',
      () async {
        final driver = _ReapableFakeDriver();
        final scheduler = LocalJobScheduler(
          driverRegistry: SimulatorDriverRegistry({driver.id: driver}),
          config: RegressionConfig(
            projectFilePath: '/fake/simcrux.yaml',
            schemaVersion: '1',
            suites: const [],
            simulatorBinaries: const {},
          ),
          runRoot: Directory.systemTemp.createTempSync('simcrux_exit').path,
        );

        final events = <RegressionEvent>[];
        final finished = Completer<RegressionFinished>();
        final request = RegressionRequest(
          runId: 'nightly',
          tests: <TestSpec>[_spec('t/a'), _spec('t/b'), _spec('t/c')],
          concurrency: 3,
        );
        final sub = scheduler.submit(request).listen((event) {
          events.add(event);
          if (event is RegressionFinished && !finished.isCompleted) {
            finished.complete(event);
          }
        });

        // Wait until every scripted simulator is actually running.
        while (driver.processes.length < 3) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(
          driver.processes.values.every((p) => !p.killed),
          isTrue,
          reason: 'precondition: the regression is mid-flight',
        );

        // The user quits.
        final registry = ActiveRunRegistry()
          ..register(() => scheduler.cancel(request.runId));
        final coordinator = AppExitCoordinator(registry: registry);
        final settled = await coordinator.shutdown();

        expect(
          settled,
          isTrue,
          reason: 'the drain must complete inside the grace budget',
        );
        expect(
          driver.processes.values.map((p) => p.killed),
          everyElement(isTrue),
          reason:
              'every in-flight simulator process tree must be reaped — '
              'exit(0) alone orphaned them',
        );

        final terminal = await finished.future;
        expect(terminal.cancelled, isTrue);
        expect(
          events.whereType<TestFinished>().map((e) => e.result.status),
          everyElement(TestStatus.cancelled),
        );
        await sub.cancel();
      },
    );

    test(
      'shutdown reaps simulators still in their COMPILE stage',
      () async {
        // The compile-stage gap the execute-stage test above cannot catch: a
        // long Verilator/GHDL compile that has not yet reached execute. Cancel
        // must route driver.cancel to the tracked compile process, and the
        // post-compile cancelled check must keep execute from spawning.
        final driver = _CompileBlockingDriver();
        final scheduler = LocalJobScheduler(
          driverRegistry: SimulatorDriverRegistry({driver.id: driver}),
          config: RegressionConfig(
            projectFilePath: '/fake/simcrux.yaml',
            schemaVersion: '1',
            suites: const [],
            simulatorBinaries: const {},
          ),
          runRoot: Directory.systemTemp
              .createTempSync('simcrux_exit_compile')
              .path,
        );

        final finished = Completer<RegressionFinished>();
        final request = RegressionRequest(
          runId: 'nightly-compile',
          tests: <TestSpec>[_spec('t/a'), _spec('t/b')],
          concurrency: 2,
        );
        final sub = scheduler.submit(request).listen((event) {
          if (event is RegressionFinished && !finished.isCompleted) {
            finished.complete(event);
          }
        });

        // Wait until every test is blocked inside compile.
        while (driver.compiledIds.length < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }

        final registry = ActiveRunRegistry()
          ..register(() => scheduler.cancel(request.runId));
        final coordinator = AppExitCoordinator(registry: registry);
        final settled = await coordinator.shutdown();

        expect(settled, isTrue);
        expect(
          driver.allCompilesKilled,
          isTrue,
          reason: 'every mid-compile process tree must be reaped on quit',
        );
        expect(
          driver.executeReached,
          isFalse,
          reason: 'a cancelled compile must not dispatch execute',
        );
        final terminal = await finished.future;
        expect(terminal.cancelled, isTrue);
        await sub.cancel();
      },
    );

    test('shutdown with no run registered still settles', () async {
      final coordinator = AppExitCoordinator(registry: ActiveRunRegistry());
      expect(await coordinator.shutdown(), isTrue);
    });
  });
}
