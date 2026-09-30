// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/cli/simcrux_cli.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/services/job_scheduler/dump_retention.dart';
import 'package:simcrux/services/job_scheduler/dump_retention_provider.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

// Both headless schedulers used to be built with the unbounded retention
// policy, so a failing test's work dir — and its waveform — was never pruned
// from `$TMPDIR/runs/` on a long-lived CI runner.

RegressionConfig _config() => RegressionConfig(
  projectFilePath: '/p/simcrux.yaml',
  schemaVersion: '1',
  suites: const [],
  simulatorBinaries: const {},
);

void main() {
  test('the app --ci scheduler prunes retained dumps by the default '
      'policy', () {
    final container = ProviderContainer(
      overrides: [
        simulatorDriverRegistryProvider.overrideWithValue(
          SimulatorDriverRegistry(const {}),
        ),
      ],
    );
    addTearDown(container.dispose);
    final scheduler =
        container.read(ciSchedulerFactoryProvider)(_config())
            as LocalJobScheduler;
    expect(scheduler.dumpRetentionPolicy.isUnbounded, isFalse);
    expect(
      scheduler.dumpRetentionPolicy,
      same(DumpRetentionPolicy.defaultPolicy),
    );
  });

  test('the app --ci scheduler follows a dumpRetentionPolicyProvider '
      'override', () {
    const custom = DumpRetentionPolicy(keepLastNFailures: 3);
    final container = ProviderContainer(
      overrides: [
        simulatorDriverRegistryProvider.overrideWithValue(
          SimulatorDriverRegistry(const {}),
        ),
        dumpRetentionPolicyProvider.overrideWithValue(custom),
      ],
    );
    addTearDown(container.dispose);
    final scheduler =
        container.read(ciSchedulerFactoryProvider)(_config())
            as LocalJobScheduler;
    expect(scheduler.dumpRetentionPolicy, same(custom));
  });

  test('the standalone binary --ci scheduler is bounded too', () {
    final cli = SimcruxCli(driverRegistry: SimulatorDriverRegistry(const {}));
    final scheduler = cli.ciSchedulerFor(_config());
    expect(scheduler.dumpRetentionPolicy.isUnbounded, isFalse);
    expect(
      scheduler.dumpRetentionPolicy,
      same(DumpRetentionPolicy.defaultPolicy),
    );
  });
}
