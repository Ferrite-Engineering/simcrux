// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_flow/crux_flow.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/interfaces/retry_policy.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/flow/flow_metric_keys.dart';
import 'package:simcrux/services/flow/flow_run_importer.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

/// The scheduler's final status for a flow result follows the flow verdict
/// alone, whatever the exit code or a detector says; and a flow run is
/// never retried.
void main() {
  group('resolveFinalStatus', () {
    TestStatus resolve(
      String verdict, {
      TestStatus classified = TestStatus.pass,
      TestStatus driver = TestStatus.pass,
      PassFailConfig config = const ExitCodePassFailConfig(),
    }) => LocalJobScheduler.resolveFinalStatus(
      classified: classified,
      driverStatus: driver,
      config: config,
      driverMetrics: <String, String>{FlowMetricKeys.verdict: verdict},
    );

    test('met passes even when the exit code said fail', () {
      expect(resolve('met', classified: TestStatus.fail), TestStatus.pass);
    });

    for (final verdict in FlowVerdict.values.where((v) => !v.isMet)) {
      test('${verdict.wireName} fails even when the exit code said pass', () {
        expect(resolve(verdict.wireName), TestStatus.fail);
      });
    }

    test('a verdict this build cannot parse fails', () {
      expect(resolve('future_verdict'), TestStatus.fail);
    });
  });

  test('a flow spec is never retried, whatever the policy says', () async {
    final driver = _CountingDriver();
    final spec = const FlowRunImporter().specFor(
      FlowEntry(
        name: 'n',
        kind: FlowKind.nextpnr,
        family: NextpnrFamily.ice40,
        device: 'up5k',
        top: 'top',
        projectRoot: Directory.systemTemp.path,
      ),
    );
    final scheduler = LocalJobScheduler(
      driverRegistry: SimulatorDriverRegistry({'nextpnr': driver}),
      config: RegressionConfig(
        projectFilePath: '/p/simcrux.yaml',
        schemaVersion: '1',
        suites: const [],
        simulatorBinaries: const <String, SimulatorBinaryConfig>{},
      ),
      retryPolicy: const _AlwaysRetry(),
    );
    final results = <TestResult>[];
    await for (final event in scheduler.submit(
      RegressionRequest(runId: 'r', tests: <TestSpec>[spec]),
    )) {
      if (event is TestFinished) results.add(event.result);
    }
    expect(driver.executions, 1);
    expect(results.single.status, TestStatus.fail);
  });
}

class _AlwaysRetry implements RetryPolicy {
  const _AlwaysRetry();

  @override
  bool shouldRetry({
    required TestSpec spec,
    required TestResult lastResult,
    required int attemptsSoFar,
    required int maxAttempts,
  }) => true;

  @override
  int? nextSeedFor({
    required TestSpec spec,
    required TestResult lastResult,
    required int attemptsSoFar,
  }) => null;
}

class _CountingDriver implements SimulatorDriver {
  int executions = 0;

  @override
  String get id => 'nextpnr';

  @override
  String get displayName => 'counting';

  @override
  SimulatorCapabilities get capabilities => SimulatorCapabilities(
    supportedLanguages: const <HdlLanguage>{},
    supportsVcd: false,
    supportsFst: false,
    supportsCocotb: false,
    requiresSeparateCompileStep: false,
    emitsStructuredOutput: true,
  );

  @override
  Future<String?> detectVersion(SimulatorBinaryConfig config) async => null;

  @override
  Future<CompileResult> compile(CompileRequest request) async =>
      const CompileResult(
        success: true,
        artifactPath: null,
        stdout: '',
        stderr: '',
      );

  @override
  Stream<TestExecutionEvent> execute(ExecuteRequest request) async* {
    executions++;
    final now = DateTime.now().toUtc();
    yield TestExecutionFinished(
      // The exit code says pass; the verdict says violated.
      status: TestStatus.pass,
      exitCode: 0,
      startedAt: now,
      finishedAt: now,
      metrics: const <String, String>{
        FlowMetricKeys.kind: 'nextpnr',
        FlowMetricKeys.verdict: 'violated',
      },
    );
  }

  @override
  void cancel(String testId) {}
}
