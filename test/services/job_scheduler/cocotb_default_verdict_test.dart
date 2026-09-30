// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/simulator/cocotb_driver.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

// End-to-end proof that a Cocotb failure survives the scheduler's
// re-classification when the project declares no `pass_fail:` block.
//
// Cocotb 1.9's `make` exits 0 when tests fail; only a missing results file
// fails the recipe. The scheduler classifies every run through the test's
// detector — `exit_code` by default — and adopts a decisive answer over the
// driver's own status. So the driver must not report the contradicting 0.
// The report below is the 1.9 shape: no count attributes on `<testsuite>`.
//
// MUTATION: report `exitCode` unconditionally in `CocotbDriver`'s
// `buildFinished`, or read only the count attributes in `parseCocotbJunit`,
// and the failing case below reports `pass`.

/// A `make` that writes [resultsXml] into the working directory (as Cocotb
/// does) and exits with [exit].
class _MakeWritingResults implements TestProcess {
  _MakeWritingResults({
    required this.workingDirectory,
    required this.resultsXml,
    required this.exit,
  });

  final String workingDirectory;
  final String resultsXml;
  final int exit;

  @override
  Stream<String> get stdout => const Stream<String>.empty();

  @override
  Stream<String> get stderr => const Stream<String>.empty();

  @override
  Future<int> get exitCode async {
    File(p.join(workingDirectory, 'results.xml')).writeAsStringSync(resultsXml);
    return exit;
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

const String _oneFailure = '''
<testsuites name="results">
  <testsuite name="all" package="all">
    <testcase name="test_pass" classname="test_dff" sim_time_ns="10.0"/>
    <testcase name="test_fail" classname="test_dff" sim_time_ns="20.0">
      <failure message="Test failed with RANDOM_SEED=1"/>
    </testcase>
  </testsuite>
</testsuites>
''';

const String _allPass = '''
<testsuites name="results">
  <testsuite name="all" package="all">
    <testcase name="test_pass" classname="test_dff" sim_time_ns="10.0"/>
  </testsuite>
</testsuites>
''';

void main() {
  late Directory runRoot;

  setUp(() {
    runRoot = Directory.systemTemp.createTempSync('simcrux_cocotb_verdict_');
  });

  tearDown(() {
    if (runRoot.existsSync()) runRoot.deleteSync(recursive: true);
  });

  Future<TestResult> runOnce({
    required String resultsXml,
    required int exit,
  }) async {
    final driver = CocotbDriver(
      launcher:
          (
            executable,
            args, {
            environment,
            workingDirectory,
          }) async => _MakeWritingResults(
            workingDirectory: workingDirectory ?? runRoot.path,
            resultsXml: resultsXml,
            exit: exit,
          ),
    );
    final scheduler = LocalJobScheduler(
      driverRegistry: SimulatorDriverRegistry({driver.id: driver}),
      config: RegressionConfig(
        projectFilePath: '/fake/simcrux.yaml',
        schemaVersion: '1',
        suites: const [],
        simulatorBinaries: const {},
      ),
      runRoot: runRoot.path,
    );
    final events = await scheduler
        .submit(
          RegressionRequest(
            runId: 'r1',
            tests: [
              // No `passFail:` — the loader's default `exit_code` detector.
              TestSpec(
                id: 'cocotb/dff',
                name: 'dff',
                suiteName: 'cocotb',
                simulatorId: 'cocotb',
                top: 'dff',
                timeout: const Duration(seconds: 30),
              ),
            ],
          ),
        )
        .toList();
    return events.whereType<TestFinished>().single.result;
  }

  test('a failing results.xml with make exit 0 is a FAIL', () async {
    final result = await runOnce(resultsXml: _oneFailure, exit: 0);
    expect(result.status, TestStatus.fail);
  });

  test('a clean results.xml with make exit 0 is a PASS', () async {
    final result = await runOnce(resultsXml: _allPass, exit: 0);
    expect(result.status, TestStatus.pass);
  });

  test('a clean results.xml with a failing recipe still fails', () async {
    final result = await runOnce(resultsXml: _allPass, exit: 2);
    expect(result.status, TestStatus.fail);
  });
}
