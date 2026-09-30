// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/providers/regression_runner.dart';
import 'package:simcrux/features/diagnostics/services/diagnostics_report.dart';

class _StubActiveConfigNotifier extends ActiveConfigNotifier {
  _StubActiveConfigNotifier(this._config);
  final RegressionConfig? _config;

  @override
  RegressionConfig? build() => _config;
}

class _StubRegressionRunner extends RegressionRunner {
  _StubRegressionRunner(this._state);
  final RegressionRunState? _state;

  @override
  Future<RegressionRunState?> build() async => _state;
}

TestSpec _spec({
  required String id,
  required String suiteName,
  String name = 'basic',
  String simulatorId = 'icarus',
}) {
  return TestSpec(
    id: id,
    name: name,
    suiteName: suiteName,
    simulatorId: simulatorId,
    top: 'tb',
  );
}

RegressionConfig _configWith(List<Suite> suites) {
  return RegressionConfig(
    projectFilePath: '/proj/simcrux.yaml',
    schemaVersion: '1',
    suites: suites,
    simulatorBinaries: const {},
  );
}

/// Pumps a minimal widget tree, captures the resolved [WidgetRef],
/// and returns it — [buildTabDiagnosticsReport] takes a `WidgetRef`
/// directly rather than a provider container, so tests need a real ref
/// from a built widget tree.
Future<WidgetRef> _refFor(
  WidgetTester tester, {
  RegressionConfig? config,
  RegressionRunState? runState,
}) async {
  late WidgetRef captured;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        activeConfigProvider.overrideWith(
          () => _StubActiveConfigNotifier(config),
        ),
        regressionRunnerProvider.overrideWith(
          () => _StubRegressionRunner(runState),
        ),
      ],
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) {
            captured = ref;
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  // `regressionRunnerProvider` is never `watch`ed by the harness
  // widget itself (only captured via `Consumer`), so force its async
  // `build()` to resolve before returning — otherwise the first
  // access from inside `buildTabDiagnosticsReport` observes
  // `AsyncLoading` and the scheduler-state section is silently
  // skipped.
  await captured.read(regressionRunnerProvider.future);
  return captured;
}

void main() {
  group('buildTabDiagnosticsReport', () {
    testWidgets('no config loaded → header + "No config loaded."', (
      tester,
    ) async {
      final ref = await _refFor(tester);
      final report = buildTabDiagnosticsReport(ref);

      expect(report, contains('SimCrux — Tab Diagnostics Report'));
      expect(report, contains('No config loaded.'));
      expect(report, contains('Simulator backend:'));
      // No scheduler section without a run.
      expect(report, isNot(contains('Scheduler state:')));
    });

    testWidgets('with a loaded config → path, schema, suite/test counts', (
      tester,
    ) async {
      final config = _configWith([
        Suite(
          name: 'cpu_unit',
          tests: [
            _spec(id: 'cpu_unit/a', suiteName: 'cpu_unit'),
            _spec(id: 'cpu_unit/b', suiteName: 'cpu_unit'),
          ],
        ),
        Suite(
          name: 'mem_unit',
          tests: [_spec(id: 'mem_unit/a', suiteName: 'mem_unit')],
        ),
      ]);
      final ref = await _refFor(tester, config: config);
      final report = buildTabDiagnosticsReport(ref);

      expect(report, contains('Config: /proj/simcrux.yaml'));
      expect(report, contains('Schema version: 1'));
      expect(report, contains('Suites: 2'));
      expect(report, contains('Tests: 3'));
    });

    testWidgets('lists every registered simulator backend id', (
      tester,
    ) async {
      final ref = await _refFor(tester);
      final report = buildTabDiagnosticsReport(ref);

      // Built-ins wired by job_scheduler_provider.dart in open-core.
      expect(report, contains('  - icarus'));
      expect(report, contains('  - verilator'));
    });

    testWidgets('with an active run → scheduler state section', (
      tester,
    ) async {
      final run = TestRun(
        id: 'run-42',
        startedAt: DateTime.utc(2026, 7, 19, 10),
        testIds: const ['a', 'b'],
        results: [
          TestResult(
            testId: 'a',
            runId: 'run-42',
            status: TestStatus.pass,
            startedAt: DateTime.utc(2026, 7, 19, 10),
            finishedAt: DateTime.utc(2026, 7, 19, 10, 0, 1),
          ),
        ],
      );
      final ref = await _refFor(
        tester,
        runState: RegressionRunState(run: run, isFinished: false),
      );
      final report = buildTabDiagnosticsReport(ref);

      expect(report, contains('Scheduler state:'));
      expect(report, contains('Run id: run-42'));
      expect(report, contains('Started: 2026-07-19T10:00:00.000Z'));
      expect(report, contains('Total tests: 2'));
      expect(report, contains('Completed: 1'));
      expect(report, contains('Finished: false'));
    });

    testWidgets('a finished run reports Finished: true', (tester) async {
      final run = TestRun(
        id: 'run-1',
        startedAt: DateTime.utc(2026),
        testIds: const ['a'],
        finishedAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
        results: [
          TestResult(
            testId: 'a',
            runId: 'run-1',
            status: TestStatus.pass,
            startedAt: DateTime.utc(2026),
            finishedAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
          ),
        ],
      );
      final ref = await _refFor(
        tester,
        runState: RegressionRunState(run: run, isFinished: true),
      );
      final report = buildTabDiagnosticsReport(ref);

      expect(report, contains('Finished: true'));
    });
  });
}
