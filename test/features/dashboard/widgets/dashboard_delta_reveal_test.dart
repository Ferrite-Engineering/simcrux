// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/trend_store.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_results_table.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/inspector/providers/test_trend_provider.dart';
import 'package:simcrux/features/inspector/widgets/run_delta_strip.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/result_store/in_memory_result_store.dart';
import 'package:simcrux/services/result_store/result_store_provider.dart';

// LOCALE_SWEEP_EXEMPT: scroll, selection and filter behaviour of the delta
// counters; the counters' text is not localised.
//
// A fresh sweep makes every test in the run new, so the "+ N new" counter
// covers the whole table. Narrowing the table to that bucket changes nothing,
// which is how the counter read as dead: clicking it must still visibly take
// the user to the tests it counts.

class _StoreNotifier extends ResultStoreNotifier {
  _StoreNotifier(this._store);
  final InMemoryResultStore _store;

  @override
  InMemoryResultStore build() => _store;
}

String _id(int i) => 'cdc/sweep_${i.toString().padLeft(2, '0')}';

Future<InMemoryResultStore> _store(int count) async {
  final store = InMemoryResultStore.forRun(
    TestRun(
      id: 'r1',
      startedAt: DateTime.utc(2026, 5),
      testIds: [for (var i = 0; i < count; i++) _id(i)],
    ),
  );
  for (var i = 0; i < count; i++) {
    await store.recordResult(
      TestResult(
        testId: _id(i),
        runId: 'r1',
        status: i.isEven ? TestStatus.pass : TestStatus.fail,
        startedAt: DateTime.utc(2026, 5),
        finishedAt: DateTime.utc(
          2026,
          5,
        ).add(const Duration(milliseconds: 50)),
      ),
    );
  }
  return store;
}

Future<void> _pump(
  WidgetTester tester, {
  required List<Override> overrides,
}) async {
  tester.view.physicalSize = const Size(1400, 500);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: const MaterialApp(
        localizationsDelegates: [
          L10N.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: L10N.supportedLocales,
        home: Scaffold(
          body: Column(
            children: [
              Expanded(child: DashboardResultsTable()),
              RunDeltaStrip(),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

double _offset(WidgetTester tester) => tester
    .state<ScrollableState>(find.byType(Scrollable).first)
    .position
    .pixels;

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(RunDeltaStrip)));

void main() {
  const total = 40;

  List<TrendDelta> allNew() => [
    for (var i = 0; i < total; i++)
      TrendDelta(
        testId: _id(i),
        currentStatus: i.isEven ? TestStatus.pass : TestStatus.fail,
        previousStatus: null,
        currentRunId: 'r1',
      ),
  ];

  testWidgets('"+ N new" over a run where every test is new takes you to the '
      'first of them', (tester) async {
    final store = await _store(total);
    await _pump(
      tester,
      overrides: [
        resultStoreProvider.overrideWith(() => _StoreNotifier(store)),
        recentTrendDeltasProvider.overrideWith((_) => allNew()),
      ],
    );
    final container = _container(tester);
    final firstId = container.read(dashboardRowsProvider).value!.first.testId;

    // The reported state: the user has scrolled the table down.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(_offset(tester), greaterThan(0));
    expect(container.read(selectedTestIdProvider), isNull);

    await tester.tap(find.text('+ $total new'));
    await tester.pumpAndSettle();

    // Visible effects: the table is back at the top, and the first new test
    // is the open one in the inspector.
    expect(_offset(tester), 0);
    expect(container.read(selectedTestIdProvider), firstId);
  });

  testWidgets('"+ N new" reveals a new test further down than the table '
      'shows', (tester) async {
    final store = await _store(total);
    await _pump(
      tester,
      overrides: [
        resultStoreProvider.overrideWith(() => _StoreNotifier(store)),
        // Only the last test is new; the rest have history.
        recentTrendDeltasProvider.overrideWith(
          (_) => [
            TrendDelta(
              testId: _id(total - 1),
              currentStatus: TestStatus.fail,
              previousStatus: null,
              currentRunId: 'r1',
            ),
            TrendDelta(
              testId: _id(0),
              currentStatus: TestStatus.pass,
              previousStatus: TestStatus.fail,
              currentRunId: 'r1',
            ),
          ],
        ),
      ],
    );
    final container = _container(tester);

    await tester.tap(find.text('+ 1 new'));
    await tester.pumpAndSettle();

    expect(container.read(selectedTestIdProvider), _id(total - 1));
    expect(find.text('sweep_${total - 1}'), findsOneWidget);
  });

  testWidgets('a counter whose tests are gone from the next run stops '
      'filtering', (tester) async {
    final store = await _store(total);
    var deltas = allNew();
    await _pump(
      tester,
      overrides: [
        resultStoreProvider.overrideWith(() => _StoreNotifier(store)),
        recentTrendDeltasProvider.overrideWith((_) => deltas),
      ],
    );
    final container = _container(tester);

    await tester.tap(find.text('+ $total new'));
    await tester.pumpAndSettle();
    expect(container.read(dashboardFilterProvider).deltaBucket, isNotNull);

    // The next run has nothing new, so no counter is drawn to switch the
    // narrowing off again.
    deltas = const [];
    container.invalidate(recentTrendDeltasProvider);
    await tester.pumpAndSettle();

    expect(container.read(dashboardFilterProvider).deltaBucket, isNull);
  });
}
