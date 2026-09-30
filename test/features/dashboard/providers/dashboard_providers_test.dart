// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/features/dashboard/models/dashboard_filter.dart';
import 'package:simcrux/features/dashboard/models/dashboard_sort.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';

TestSpec _spec({
  required String id,
  required String suiteName,
  required String name,
  String simulatorId = 'icarus',
  String top = 'tb',
}) {
  return TestSpec(
    id: id,
    name: name,
    suiteName: suiteName,
    simulatorId: simulatorId,
    top: top,
  );
}

TestResult _result(
  String testId,
  TestStatus status,
  Duration runtime, {
  String runId = 'r1',
  DateTime? startedAt,
}) {
  final started = startedAt ?? DateTime.utc(2026, 5);
  return TestResult(
    testId: testId,
    runId: runId,
    status: status,
    startedAt: started,
    finishedAt: started.add(runtime),
  );
}

RegressionConfig _configFor(List<TestSpec> tests) {
  final byId = <String, List<TestSpec>>{};
  for (final t in tests) {
    byId.putIfAbsent(t.suiteName, () => <TestSpec>[]).add(t);
  }
  return RegressionConfig(
    projectFilePath: '/proj/simcrux.yaml',
    schemaVersion: '1',
    suites: [
      for (final entry in byId.entries)
        Suite(name: entry.key, tests: entry.value),
    ],
    simulatorBinaries: const {},
  );
}

TestRun _run(List<TestResult> results) {
  return TestRun(
    id: 'r1',
    startedAt: DateTime.utc(2026, 5),
    testIds: results.map((r) => r.testId).toList(),
    results: results,
  );
}

void main() {
  group('filterAndSortDashboardRows', () {
    test('joins results with TestSpec metadata from the active config', () {
      final rows = filterAndSortDashboardRows(
        run: _run([
          _result(
            'unit/alu',
            TestStatus.pass,
            const Duration(milliseconds: 50),
          ),
        ]),
        config: _configFor([
          _spec(id: 'unit/alu', suiteName: 'unit', name: 'alu'),
        ]),
        filter: DashboardFilter.unset,
        sort: const DashboardSort(),
      );
      expect(rows, hasLength(1));
      expect(rows.single.suiteName, 'unit');
      expect(rows.single.testName, 'alu');
      expect(rows.single.simulatorId, 'icarus');
      expect(rows.single.result.status, TestStatus.pass);
    });

    test('falls back to id-prefix split when no config is active', () {
      final rows = filterAndSortDashboardRows(
        run: _run([
          _result(
            'unit/alu',
            TestStatus.pass,
            const Duration(milliseconds: 50),
          ),
        ]),
        config: null,
        filter: DashboardFilter.unset,
        sort: const DashboardSort(),
      );
      expect(rows.single.suiteName, 'unit');
      expect(rows.single.testName, 'alu');
      expect(rows.single.simulatorId, 'unknown');
    });

    test('applies the status filter', () {
      final rows = filterAndSortDashboardRows(
        run: _run([
          _result(
            'unit/alu',
            TestStatus.pass,
            const Duration(milliseconds: 50),
          ),
          _result(
            'unit/regfile',
            TestStatus.fail,
            const Duration(milliseconds: 80),
          ),
        ]),
        config: null,
        filter: DashboardFilter(statuses: const {TestStatus.fail}),
        sort: const DashboardSort(),
      );
      expect(rows.map((r) => r.testId), ['unit/regfile']);
    });

    test('applies the substring filter (case-insensitive)', () {
      final rows = filterAndSortDashboardRows(
        run: _run([
          _result('unit/alu', TestStatus.pass, const Duration(milliseconds: 1)),
          _result(
            'unit/REGFILE',
            TestStatus.pass,
            const Duration(milliseconds: 1),
          ),
        ]),
        config: null,
        filter: DashboardFilter(testNameSubstring: 'regfile'),
        sort: const DashboardSort(),
      );
      expect(rows.map((r) => r.testId), ['unit/REGFILE']);
    });

    test('applies the suite filter', () {
      final rows = filterAndSortDashboardRows(
        run: _run([
          _result('unit/alu', TestStatus.pass, Duration.zero),
          _result('random/long', TestStatus.pass, Duration.zero),
        ]),
        config: null,
        filter: DashboardFilter(suites: const {'unit'}),
        sort: const DashboardSort(),
      );
      expect(rows.map((r) => r.testId), ['unit/alu']);
    });

    test('applies the runtime range filter', () {
      final rows = filterAndSortDashboardRows(
        run: _run([
          _result(
            'unit/fast',
            TestStatus.pass,
            const Duration(milliseconds: 5),
          ),
          _result('unit/slow', TestStatus.pass, const Duration(seconds: 5)),
        ]),
        config: null,
        filter: DashboardFilter(
          minRuntime: const Duration(seconds: 1),
        ),
        sort: const DashboardSort(),
      );
      expect(rows.map((r) => r.testId), ['unit/slow']);
    });

    test('sorts by suite ascending when configured', () {
      final rows = filterAndSortDashboardRows(
        run: _run([
          _result('zz/last', TestStatus.pass, Duration.zero),
          _result('aa/first', TestStatus.pass, Duration.zero),
        ]),
        config: null,
        filter: DashboardFilter.unset,
        sort: const DashboardSort(
          column: DashboardSortColumn.suite,
          direction: DashboardSortDirection.ascending,
        ),
      );
      expect(rows.map((r) => r.suiteName).toList(), ['aa', 'zz']);
    });

    test('sorts by duration descending when configured', () {
      final rows = filterAndSortDashboardRows(
        run: _run([
          _result(
            'unit/fast',
            TestStatus.pass,
            const Duration(milliseconds: 5),
          ),
          _result('unit/slow', TestStatus.pass, const Duration(seconds: 5)),
        ]),
        config: null,
        filter: DashboardFilter.unset,
        sort: const DashboardSort(
          column: DashboardSortColumn.duration,
        ),
      );
      expect(rows.map((r) => r.testId).toList(), ['unit/slow', 'unit/fast']);
    });
  });

  group('DashboardTotals.fromRun', () {
    test('counts by status', () {
      final totals = DashboardTotals.fromRun(
        _run([
          _result('a/p', TestStatus.pass, Duration.zero),
          _result('a/f', TestStatus.fail, Duration.zero),
          _result('a/t', TestStatus.timeout, Duration.zero),
        ]),
      );
      expect(totals.total, 3);
      expect(totals.countOf(TestStatus.pass), 1);
      expect(totals.countOf(TestStatus.fail), 1);
      expect(totals.countOf(TestStatus.timeout), 1);
    });
  });

  group('DashboardFilterNotifier mutators', () {
    test('toggleStatus toggles set membership', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(dashboardFilterProvider.notifier)
        ..toggleStatus(TestStatus.pass);
      expect(container.read(dashboardFilterProvider).statuses, {
        TestStatus.pass,
      });
      notifier.toggleStatus(TestStatus.pass);
      expect(container.read(dashboardFilterProvider).statuses, isEmpty);
    });

    test('reset clears every axis', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(dashboardFilterProvider.notifier)
        ..toggleStatus(TestStatus.pass)
        ..toggleSuite('unit')
        ..setTestNameSubstring('alu');
      expect(container.read(dashboardFilterProvider).isUnset, isFalse);
      container.read(dashboardFilterProvider.notifier).reset();
      expect(container.read(dashboardFilterProvider).isUnset, isTrue);
    });
  });

  group('DashboardSelectionNotifier', () {
    test('toggle adds and removes ids', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(dashboardSelectionProvider.notifier);
      expect(container.read(dashboardSelectionProvider), isEmpty);
      notifier.toggle('a');
      expect(container.read(dashboardSelectionProvider), {'a'});
      notifier.toggle('a');
      expect(container.read(dashboardSelectionProvider), isEmpty);
    });

    test('selectAll merges into the current selection', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(dashboardSelectionProvider.notifier)
        ..toggle('a')
        ..selectAll(['b', 'c']);
      expect(container.read(dashboardSelectionProvider), {'a', 'b', 'c'});
    });
  });

  group('ActiveConfigNotifier', () {
    test('replace and clear update the provider state', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(activeConfigProvider), isNull);
      final config = _configFor([
        _spec(id: 'unit/alu', suiteName: 'unit', name: 'alu'),
      ]);
      container.read(activeConfigProvider.notifier).replace(config);
      expect(container.read(activeConfigProvider), same(config));
      container.read(activeConfigProvider.notifier).clear();
      expect(container.read(activeConfigProvider), isNull);
    });
  });
}
