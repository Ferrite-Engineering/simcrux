// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/trend_store.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_results_table.dart';
import 'package:simcrux/features/dashboard/widgets/test_browser_panel.dart';
import 'package:simcrux/features/inspector/providers/test_trend_provider.dart';
import 'package:simcrux/features/inspector/widgets/run_delta_strip.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/result_store/in_memory_result_store.dart';
import 'package:simcrux/services/result_store/result_store_provider.dart';

// Reproduces the two defects in the results table reported from a live
// seed sweep: the "+ N new" counter did nothing when clicked, and every
// seeded run read as the same bare test name.

TestResult _result(String id, TestStatus status) => TestResult(
  testId: id,
  runId: 'r1',
  status: status,
  startedAt: DateTime.utc(2026, 5),
  finishedAt: DateTime.utc(2026, 5).add(const Duration(milliseconds: 50)),
);

TestSpec _seeded(int seed) => TestSpec(
  id: 'cdc/cdc_capture_sweep+seed=$seed',
  name: 'cdc_capture_sweep',
  suiteName: 'cdc',
  simulatorId: 'verilator',
  top: 'tb',
  seed: seed,
  parentSpecId: 'cdc/cdc_capture_sweep',
);

TestSpec _plain(String name) => TestSpec(
  id: 'cdc/$name',
  name: name,
  suiteName: 'cdc',
  simulatorId: 'verilator',
  top: 'tb',
);

RegressionConfig _config(List<TestSpec> tests) => RegressionConfig(
  projectFilePath: '/proj/simcrux.yaml',
  schemaVersion: '1',
  suites: [Suite(name: 'cdc', tests: tests)],
  simulatorBinaries: const {},
);

class _StoreNotifier extends ResultStoreNotifier {
  _StoreNotifier(this._store);
  final InMemoryResultStore _store;

  @override
  InMemoryResultStore build() => _store;
}

class _ConfigNotifier extends ActiveConfigNotifier {
  _ConfigNotifier(this._config);
  final RegressionConfig _config;

  @override
  RegressionConfig? build() => _config;
}

Future<InMemoryResultStore> _store(Map<String, TestStatus> byId) async {
  final store = InMemoryResultStore.forRun(
    TestRun(
      id: 'r1',
      startedAt: DateTime.utc(2026, 5),
      testIds: byId.keys.toList(),
    ),
  );
  for (final e in byId.entries) {
    await store.recordResult(_result(e.key, e.value));
  }
  return store;
}

Future<void> _pump(
  WidgetTester tester, {
  required Widget body,
  required List<Override> overrides,
  Locale locale = const Locale('en'),
}) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: const [
          L10N.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: L10N.supportedLocales,
        home: Scaffold(body: body),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('"+ N new" counter', () {
    Future<void> pumpTableWithStrip(WidgetTester tester) async {
      final store = await _store({
        'cdc/old_a': TestStatus.pass,
        'cdc/new_b': TestStatus.pass,
        'cdc/new_c': TestStatus.fail,
      });
      await _pump(
        tester,
        body: const Column(
          children: [
            Expanded(child: DashboardResultsTable()),
            RunDeltaStrip(),
          ],
        ),
        overrides: [
          resultStoreProvider.overrideWith(() => _StoreNotifier(store)),
          recentTrendDeltasProvider.overrideWith(
            (_) => const [
              TrendDelta(
                testId: 'cdc/old_a',
                currentStatus: TestStatus.pass,
                previousStatus: TestStatus.fail,
                currentRunId: 'r1',
              ),
              TrendDelta(
                testId: 'cdc/new_b',
                currentStatus: TestStatus.pass,
                previousStatus: null,
                currentRunId: 'r1',
              ),
              TrendDelta(
                testId: 'cdc/new_c',
                currentStatus: TestStatus.fail,
                previousStatus: null,
                currentRunId: 'r1',
              ),
            ],
          ),
        ],
      );
    }

    testWidgets('tapping it narrows the table to the new tests', (
      tester,
    ) async {
      await pumpTableWithStrip(tester);
      expect(find.text('old_a'), findsOneWidget);
      expect(find.text('new_b'), findsOneWidget);

      await tester.tap(find.text('+ 2 new'));
      await tester.pumpAndSettle();

      expect(find.text('old_a'), findsNothing);
      expect(find.text('new_b'), findsOneWidget);
      expect(find.text('new_c'), findsOneWidget);
    });

    testWidgets('tapping it again clears the narrowing', (tester) async {
      await pumpTableWithStrip(tester);

      await tester.tap(find.text('+ 2 new'));
      await tester.pumpAndSettle();
      expect(find.text('old_a'), findsNothing);

      await tester.tap(find.text('+ 2 new'));
      await tester.pumpAndSettle();
      expect(find.text('old_a'), findsOneWidget);
      expect(find.text('new_b'), findsOneWidget);
    });
  });

  group('seeded runs', () {
    final specs = [_seeded(21), _seeded(22), _plain('smoke')];

    testWidgets("the results table shows each row's seed", (tester) async {
      final store = await _store({
        'cdc/cdc_capture_sweep+seed=21': TestStatus.pass,
        'cdc/cdc_capture_sweep+seed=22': TestStatus.fail,
        'cdc/smoke': TestStatus.pass,
      });
      await _pump(
        tester,
        body: const DashboardResultsTable(),
        overrides: [
          resultStoreProvider.overrideWith(() => _StoreNotifier(store)),
          activeConfigProvider.overrideWith(
            () => _ConfigNotifier(_config(specs)),
          ),
        ],
      );

      expect(find.text('cdc_capture_sweep · seed 21'), findsOneWidget);
      expect(find.text('cdc_capture_sweep · seed 22'), findsOneWidget);
      // A test that was not swept keeps its plain name.
      expect(find.text('smoke'), findsOneWidget);
    });

    testWidgets('every locale renders the seeded name without exceptions', (
      tester,
    ) async {
      for (final locale in L10N.supportedLocales) {
        await _pump(
          tester,
          locale: locale,
          body: const TestBrowserPanel(),
          overrides: [
            activeConfigProvider.overrideWith(
              () => _ConfigNotifier(_config(specs)),
            ),
            dashboardRowsProvider.overrideWith((ref) => Stream.value([])),
          ],
        );
        expect(tester.takeException(), isNull, reason: '$locale');
        expect(find.textContaining('21'), findsOneWidget, reason: '$locale');
      }
    });

    testWidgets("the tests tree shows each test's seed", (tester) async {
      await _pump(
        tester,
        body: const TestBrowserPanel(),
        overrides: [
          activeConfigProvider.overrideWith(
            () => _ConfigNotifier(_config(specs)),
          ),
          dashboardRowsProvider.overrideWith((ref) => Stream.value([])),
        ],
      );

      expect(find.text('cdc_capture_sweep · seed 21'), findsOneWidget);
      expect(find.text('cdc_capture_sweep · seed 22'), findsOneWidget);
      expect(find.text('smoke'), findsOneWidget);
    });
  });
}
