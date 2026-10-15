// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/run_delta_bucket.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/features/dashboard/models/dashboard_filter.dart';
import 'package:simcrux/features/dashboard/models/dashboard_sort.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';

TestSpec _spec(String id, {int? seed, String? parent}) => TestSpec(
  id: id,
  name: 'sweep',
  suiteName: 'cdc',
  simulatorId: 'verilator',
  top: 'tb',
  seed: seed,
  parentSpecId: parent,
);

void main() {
  group('TestSpec.sweepSeed', () {
    test('is the seed of a swept instance', () {
      expect(
        _spec('cdc/sweep+seed=7', seed: 7, parent: 'cdc/sweep').sweepSeed,
        7,
      );
    });

    test('is null for a plain test that pins a scalar seed', () {
      expect(_spec('cdc/sweep', seed: 7).sweepSeed, isNull);
    });

    test('is null when there is no seed', () {
      expect(_spec('cdc/sweep').sweepSeed, isNull);
    });
  });

  group('dashboard rows for a seed sweep', () {
    final specs = [
      for (final seed in [10, 2, 33])
        _spec('cdc/sweep+seed=$seed', seed: seed, parent: 'cdc/sweep'),
    ];
    final config = RegressionConfig(
      projectFilePath: '/p/simcrux.yaml',
      schemaVersion: '1',
      suites: [Suite(name: 'cdc', tests: specs)],
      simulatorBinaries: const {},
    );
    final run = TestRun(
      id: 'r1',
      startedAt: DateTime.utc(2026),
      testIds: [for (final s in specs) s.id],
      results: [
        for (final s in specs)
          TestResult(
            runId: 'r1',
            testId: s.id,
            status: TestStatus.pass,
            startedAt: DateTime.utc(2026),
            finishedAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
          ),
      ],
    );

    test('carry their seed and sort by it under the Test column', () {
      final rows = filterAndSortDashboardRows(
        run: run,
        config: config,
        filter: DashboardFilter.unset,
        sort: const DashboardSort(
          column: DashboardSortColumn.testName,
          direction: DashboardSortDirection.ascending,
        ),
      );
      expect([for (final r in rows) r.seed], [2, 10, 33]);
    });

    test('a delta bucket keeps only the tests behind it', () {
      final rows = filterAndSortDashboardRows(
        run: run,
        config: config,
        filter: DashboardFilter(deltaBucket: RunDeltaBucket.newTests),
        sort: const DashboardSort(
          column: DashboardSortColumn.testName,
          direction: DashboardSortDirection.ascending,
        ),
        deltaIds: {'cdc/sweep+seed=2'},
      );
      expect([for (final r in rows) r.seed], [2]);
    });
  });

  group('DashboardFilter.deltaBucket', () {
    test('counts as a constraint and takes part in equality', () {
      final filter = DashboardFilter(deltaBucket: RunDeltaBucket.fixed);
      expect(filter.isUnset, isFalse);
      expect(filter, isNot(DashboardFilter.unset));
      expect(filter, DashboardFilter(deltaBucket: RunDeltaBucket.fixed));
    });

    test('copyWith keeps it unless told to clear it', () {
      final filter = DashboardFilter(deltaBucket: RunDeltaBucket.fixed);
      expect(filter.copyWith(testNameSubstring: 'x').deltaBucket, isNotNull);
      expect(filter.copyWith(clearDeltaBucket: true).isUnset, isTrue);
    });
  });
}
