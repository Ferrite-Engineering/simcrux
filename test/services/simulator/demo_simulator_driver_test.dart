// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/simulator/demo_simulator_driver.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

TestSpec _spec(String id) => TestSpec(
  id: id,
  name: id.split('/').last,
  suiteName: id.split('/').first,
  simulatorId: DemoSimulatorDriver.kId,
  top: 'tb',
);

ExecuteRequest _executeRequest(String testId) => ExecuteRequest(
  test: _spec(testId),
  workingDirectory: '/tmp/demo',
  compileResult: null,
  // `source` is omitted deliberately: it defaults to
  // SimulatorBinarySource.system, and restating it trips
  // avoid_redundant_argument_values under --fatal-infos.
  binaryConfig: const SimulatorBinaryConfig(
    simulatorId: DemoSimulatorDriver.kId,
  ),
);

void main() {
  group('DemoSimulatorDriver', () {
    test(
      'spawns no process and yields a deterministic terminal event',
      () async {
        const driver = DemoSimulatorDriver();
        expect(driver.id, 'demo');

        final events = await driver
            .execute(_executeRequest('unit/alu'))
            .toList();
        final finished = events.whereType<TestExecutionFinished>().single;
        expect(finished.status, anyOf(TestStatus.pass, TestStatus.fail));
        expect(finished.effectiveSeed, isNotNull);

        // Deterministic: the same test id yields the same outcome twice.
        final again = await driver
            .execute(_executeRequest('unit/alu'))
            .toList();
        expect(
          again.whereType<TestExecutionFinished>().single.status,
          finished.status,
        );
      },
    );
  });

  group('demoRunnerEnabledProvider gates registry wiring', () {
    test('the demo driver is hidden by default', () {
      final container = ProviderContainer(
        overrides: [demoRunnerEnabledProvider.overrideWithValue(false)],
      );
      addTearDown(container.dispose);
      final registry = container.read(simulatorDriverRegistryProvider);
      expect(registry.driverFor(DemoSimulatorDriver.kId), isNull);
      // The real built-ins are always present.
      expect(registry.driverFor('icarus'), isNotNull);
    });

    test('enabling the gate registers the demo driver', () {
      final container = ProviderContainer(
        overrides: [demoRunnerEnabledProvider.overrideWithValue(true)],
      );
      addTearDown(container.dispose);
      final registry = container.read(simulatorDriverRegistryProvider);
      expect(
        registry.driverFor(DemoSimulatorDriver.kId),
        isA<DemoSimulatorDriver>(),
      );
    });
  });

  group('demo run populates dashboard rows', () {
    test('a run over N demo specs yields N finished results', () async {
      final scheduler = LocalJobScheduler(
        driverRegistry: SimulatorDriverRegistry({
          DemoSimulatorDriver.kId: const DemoSimulatorDriver(),
        }),
        config: RegressionConfig(
          projectFilePath: '/tmp/demo/simcrux.yaml',
          schemaVersion: '1',
          suites: const [],
          simulatorBinaries: const {},
        ),
      );

      final specs = [for (var i = 0; i < 12; i++) _spec('unit/t$i')];
      final results = <TestFinished>[];
      await for (final event in scheduler.submit(
        RegressionRequest(runId: 'demo-run', tests: specs, concurrency: 4),
      )) {
        if (event is TestFinished) results.add(event);
      }

      // Every demo spec produced a row — no real simulator required.
      expect(results.length, specs.length);
      expect(
        results.map((r) => r.result.testId).toSet(),
        specs.map((s) => s.id).toSet(),
      );
    });
  });
}
