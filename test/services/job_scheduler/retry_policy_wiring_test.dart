// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/interfaces/retry_policy.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/retry_policy/retry_policy_provider.dart';
import 'package:simcrux/services/simulator/icarus_driver.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

/// Guards the two halves of the scheduler ↔ retry-policy seam:
///
/// 1. `jobSchedulerProvider` must build the scheduler with the
///    **overridden** `retryPolicyProvider` — not fall back to its
///    `LocalJobScheduler`-default `NoopRetryPolicy`. If the provider ever
///    stops passing `retryPolicy:`, the Pro override of
///    `retryPolicyProvider` goes dead: no injected policy reaches the
///    run loop.
/// 2. When the injected policy is a [PreparableRetryPolicy] the scheduler
///    must `prepareForRun` at run start (before the first test executes),
///    so a policy whose synchronous decisions read from an async-primed
///    cache sees a warm cache on the first failure.
class _FakeProcess implements TestProcess {
  _FakeProcess(this.exit);
  final int exit;
  @override
  Stream<String> get stdout => const Stream<String>.empty();
  @override
  Stream<String> get stderr => const Stream<String>.empty();
  @override
  Future<int> get exitCode async => exit;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

/// Spy policy: records the specs it was primed with and how many times
/// `shouldRetry` was consulted, and retries exactly once so the run
/// visibly reflects the injected decision (Noop would never retry).
class _SpyPolicy implements RetryPolicy, PreparableRetryPolicy {
  final List<String> preparedSpecIds = <String>[];
  int shouldRetryCalls = 0;

  @override
  Future<void> prepareForRun(Iterable<TestSpec> specs) async {
    preparedSpecIds.addAll(specs.map((s) => s.id));
  }

  @override
  bool shouldRetry({
    required TestSpec spec,
    required TestResult lastResult,
    required int attemptsSoFar,
    required int maxAttempts,
  }) {
    shouldRetryCalls++;
    return attemptsSoFar < 2; // one retry, then stop
  }

  @override
  int? nextSeedFor({
    required TestSpec spec,
    required TestResult lastResult,
    required int attemptsSoFar,
  }) => null;
}

void main() {
  test(
    'jobSchedulerProvider wires the overridden retryPolicyProvider and '
    'prepares it at run start',
    () async {
      final tmp = Directory.systemTemp.createTempSync('simcrux_retrywire_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      var vvpLaunches = 0;
      Future<TestProcess> launch(
        String executable,
        List<String> args, {
        Map<String, String>? environment,
        String? workingDirectory,
      }) async {
        if (executable.contains('iverilog')) {
          File(
            p.join(workingDirectory!, 'sim.vvp'),
          ).createSync(recursive: true);
          return _FakeProcess(0);
        }
        // vvp (execute): count it and fail so the retry policy is consulted.
        vvpLaunches++;
        return _FakeProcess(1);
      }

      final driver = IcarusDriver(launcher: launch);
      final spy = _SpyPolicy();
      final config = RegressionConfig(
        projectFilePath: '/p/simcrux.yaml',
        schemaVersion: '1',
        suites: const [],
        simulatorBinaries: const {},
      );

      final container = ProviderContainer(
        overrides: [
          retryPolicyProvider.overrideWithValue(spy),
          simulatorDriverRegistryProvider.overrideWithValue(
            SimulatorDriverRegistry({driver.id: driver}),
          ),
        ],
      );
      addTearDown(container.dispose);

      // The provider does not expose runRoot, so drive the scheduler the
      // provider builds directly for the run itself — but read it through
      // the provider so the wiring (retryPolicy + driver registry) is the
      // thing under test.
      final providerBuilt = container
          .read(jobSchedulerProvider)
          .schedulerFor(config);
      // Sanity: the provider produced a LocalJobScheduler carrying the
      // injected spy (not the NoopRetryPolicy default).
      expect(providerBuilt, isA<LocalJobScheduler>());
      expect(
        (providerBuilt as LocalJobScheduler).retryPolicy,
        same(spy),
        reason: 'jobSchedulerProvider must inject retryPolicyProvider',
      );

      // Run through a scheduler with the same wiring but a test-owned
      // runRoot so no work escapes the temp dir.
      final scheduler = LocalJobScheduler(
        driverRegistry: SimulatorDriverRegistry({driver.id: driver}),
        config: config,
        runRoot: tmp.path,
        retryPolicy: spy,
      );
      final spec = TestSpec(
        id: 'unit/alu',
        name: 'alu',
        suiteName: 'unit',
        simulatorId: 'icarus',
        top: 'tb',
      );
      final events = await scheduler
          .submit(RegressionRequest(runId: 'r1', tests: [spec]))
          .toList();

      // prepareForRun ran at run start with the run's specs.
      expect(spy.preparedSpecIds, ['unit/alu']);
      // The injected policy actually drove the run: it was consulted and
      // its "retry once" decision produced a second attempt.
      expect(spy.shouldRetryCalls, greaterThanOrEqualTo(1));
      expect(vvpLaunches, 2, reason: 'original + one policy-driven retry');
      expect(events.whereType<TestFinished>(), hasLength(1));
    },
  );
}
