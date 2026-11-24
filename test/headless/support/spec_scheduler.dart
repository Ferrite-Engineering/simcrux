// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// The scheduler the spec's `run` cases execute on: each test's result is
/// read off its name, with fixed times, so a run's document is the same
/// bytes every time and on every machine.
///
/// | name ends in | status | what else |
/// |---|---|---|
/// | `_fail` | fail | exit 1, seed 7, parameter WIDTH=8, the message `ERROR: <name>: expected 0x3, got 0x4`, log `logs/<suite>_<name>.txt`, waveform `waves/<name>.vcd` |
/// | `_unknown` | unknown | the message `scheduler error: the driver stopped answering`, log `logs/<suite>_<name>.txt` |
/// | `_vacuous` | vacuous | exit 0 |
/// | `_missing` | fail, simulator never ran | the message ``scripted binary `scripted-sim` not available (path).`` |
/// | anything else | pass | exit 0, no log (a passing test's work folder is removed) |
///
/// Test i (from 0, in submission order) starts at 2026-11-20 09:00:0i UTC
/// and runs (i + 1) x 100 ms.
library;

import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/resource_lock.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';

/// A [JobScheduler] whose results are read off the tests' names.
class SpecScheduler implements JobScheduler {
  /// Results under [root]; with [hold], nothing is reported until the run is
  /// cancelled, as for a run that is still going.
  SpecScheduler({required this.root, this.hold = false});

  /// Where the logs and waveforms the results name are.
  final String root;

  /// Whether the run waits to be cancelled.
  final bool hold;

  /// The run ids [cancel] was called with.
  final List<String> cancelled = <String>[];

  /// Completes when a run has been submitted.
  final Completer<void> submitted = Completer<void>();

  final Map<String, StreamController<RegressionEvent>> _runs =
      <String, StreamController<RegressionEvent>>{};

  /// The result the scheduler reports for [spec], the [index]th submitted.
  TestResult resultFor(TestSpec spec, int index, String runId) {
    final started = DateTime.utc(2026, 11, 20, 9, 0, index);
    final finished = started.add(Duration(milliseconds: (index + 1) * 100));
    final log = p.join(root, 'logs', '${spec.suiteName}_${spec.name}.txt');
    final name = spec.name;
    if (name.endsWith('_fail')) {
      return TestResult(
        testId: spec.id,
        runId: runId,
        status: TestStatus.fail,
        startedAt: started,
        finishedAt: finished,
        exitCode: 1,
        stdoutPath: log,
        waveformPath: p.join(root, 'waves', '$name.vcd'),
        failureMessage: 'ERROR: $name: expected 0x3, got 0x4',
        executionSeed: 7,
        boundParameters: const <String, String>{'WIDTH': '8'},
      );
    }
    if (name.endsWith('_unknown')) {
      return TestResult(
        testId: spec.id,
        runId: runId,
        status: TestStatus.unknown,
        startedAt: started,
        finishedAt: finished,
        stdoutPath: log,
        failureMessage: 'scheduler error: the driver stopped answering',
      );
    }
    if (name.endsWith('_vacuous')) {
      return TestResult(
        testId: spec.id,
        runId: runId,
        status: TestStatus.vacuous,
        startedAt: started,
        finishedAt: finished,
        exitCode: 0,
      );
    }
    if (name.endsWith('_missing')) {
      return TestResult(
        testId: spec.id,
        runId: runId,
        status: TestStatus.fail,
        startedAt: started,
        finishedAt: started,
        failureMessage: 'scripted binary `scripted-sim` not available (path).',
        didExecute: false,
      );
    }
    return TestResult(
      testId: spec.id,
      runId: runId,
      status: TestStatus.pass,
      startedAt: started,
      finishedAt: finished,
      exitCode: 0,
    );
  }

  @override
  Stream<RegressionEvent> submit(RegressionRequest request) {
    final controller = StreamController<RegressionEvent>();
    _runs[request.runId] = controller;
    if (!submitted.isCompleted) submitted.complete();
    if (!hold) {
      var i = 0;
      for (final spec in request.tests) {
        controller.add(
          TestFinished(
            runId: request.runId,
            result: resultFor(spec, i++, request.runId),
          ),
        );
      }
      controller.add(
        RegressionFinished(runId: request.runId, cancelled: false),
      );
      unawaited(controller.close());
    }
    return controller.stream;
  }

  @override
  Future<void> cancel(String runId) async {
    cancelled.add(runId);
    final controller = _runs[runId];
    if (controller == null || controller.isClosed) return;
    controller.add(RegressionFinished(runId: runId, cancelled: true));
    await controller.close();
  }

  @override
  RegressionStatus statusOf(String runId) => RegressionStatus(
    runId: runId,
    totalTests: 0,
    completedTests: 0,
    runningTests: 0,
    isFinished: _runs[runId]?.isClosed ?? true,
  );

  @override
  Map<String, ResourceLock> get heldLocks => const <String, ResourceLock>{};
}
