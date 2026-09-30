// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/result_store.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_results_table.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/result_store/in_memory_result_store.dart';
import 'package:simcrux/services/result_store/result_store_provider.dart';

/// The results dashboard must stay interactive at 10,000 rows: the
/// table is virtualized (`ListView.builder`), so only the rows in (and
/// near) the viewport are ever built, regardless of total row count.
///
/// MUTATION: replacing the virtualized list with a non-virtualized
/// `Column`/`ListView(children: …)` of all rows realizes all 10,000 rows
/// (and 10,000 `Checkbox`es), blowing past the realized-row bound below.
void main() {
  _streamingBench();

  testWidgets('a 10k-row table realizes only the visible rows', (tester) async {
    const total = 10000;
    final started = DateTime.utc(2026, 6, 10);
    final results = <TestResult>[
      for (var i = 0; i < total; i++)
        TestResult(
          testId: 'suite/t$i',
          runId: 'r1',
          status: i.isEven ? TestStatus.pass : TestStatus.fail,
          startedAt: started,
          finishedAt: started.add(const Duration(milliseconds: 50)),
        ),
    ];
    final run = TestRun(
      id: 'r1',
      startedAt: started,
      testIds: [for (var i = 0; i < total; i++) 'suite/t$i'],
      results: results,
    );
    final store = InMemoryResultStore.forRun(run);

    await tester.binding.setSurfaceSize(const Size(1200, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final sw = Stopwatch()..start();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          resultStoreProvider.overrideWith(
            () => _ImmediateResultStoreNotifier(store),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: [
            L10N.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: L10N.supportedLocales,
          home: Scaffold(body: DashboardResultsTable()),
        ),
      ),
    );
    await tester.pump();
    sw.stop();

    expect(tester.takeException(), isNull);

    // Each row renders exactly one Checkbox. A virtualized list builds only
    // the viewport's rows (+ a small cache window) — never all 10k.
    final realizedRows = tester.widgetList(find.byType(Checkbox)).length;
    expect(realizedRows, greaterThan(0));
    expect(
      realizedRows,
      lessThan(100),
      reason: '$realizedRows rows realized — the table must be virtualized',
    );

    // Soft, CI-tolerant: building the virtualized table is cheap even at
    // 10k rows because the row work is bounded by the viewport.
    expect(sw.elapsedMilliseconds, lessThan(2000));
  });
}

class _ImmediateResultStoreNotifier extends ResultStoreNotifier {
  _ImmediateResultStoreNotifier(this._store);
  final InMemoryResultStore _store;

  @override
  InMemoryResultStore build() => _store;
}

/// Streaming-run scenario: N results arriving fast must not
/// trigger per-result full-pipeline recomputation. Guards the three
/// mechanisms together:
///
/// * the result store publishes a live [TestRun.view] instead of
///   copying the full result list per result (was O(n²) per run);
/// * `dashboardRows` builds the specsById map once per config, not
///   per emission;
/// * rows/totals recomputation is coalesced to
///   [kDashboardCoalesceWindow] (~10 Hz), leading edge immediate +
///   trailing-edge flush, so the final state is never dropped.
///
/// MUTATION: reverting the store to per-result `copyWith` copies, or
/// removing `coalesceLatest`, blows the emission bound (every result
/// produces a rows rebuild) and — for the store copy — the elapsed
/// bound at larger N.
void _streamingBench() {
  testWidgets('streaming run: 2000 fast results coalesce to few rebuilds', (
    tester,
  ) async {
    const total = 2000;
    final started = DateTime.utc(2026, 6, 10);
    final testIds = [for (var i = 0; i < total; i++) 'suite/t$i'];
    final run = TestRun(id: 'r1', startedAt: started, testIds: testIds);
    final store = InMemoryResultStore.forRun(run);
    // Realistic config so the specsById join path is exercised (its
    // per-emission rebuild was half the quadratic cost).
    final config = RegressionConfig(
      projectFilePath: '/bench/simcrux.yaml',
      schemaVersion: '1',
      suites: [
        Suite(
          name: 'suite',
          tests: [
            for (var i = 0; i < total; i++)
              TestSpec(
                id: 'suite/t$i',
                name: 't$i',
                suiteName: 'suite',
                simulatorId: 'icarus',
                top: 'tb',
              ),
          ],
        ),
      ],
      simulatorBinaries: const {},
    );

    await tester.binding.setSurfaceSize(const Size(1200, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          resultStoreProvider.overrideWith(
            () => _ImmediateResultStoreNotifier(store),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: [
            L10N.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: L10N.supportedLocales,
          home: Scaffold(body: DashboardResultsTable()),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DashboardResultsTable)),
    );
    container.read(activeConfigProvider.notifier).replace(config);
    await tester.pump();

    var rowsRebuilds = 0;
    var latestRowCount = -1;
    final sub = container.listen(dashboardRowsProvider, (_, next) {
      final rows = next.value;
      if (rows == null) return;
      rowsRebuilds++;
      latestRowCount = rows.length;
    });
    addTearDown(sub.close);

    final sw = Stopwatch()..start();
    for (var i = 0; i < total; i++) {
      await store.recordResult(
        TestResult(
          testId: 'suite/t$i',
          runId: 'r1',
          status: i.isEven ? TestStatus.pass : TestStatus.fail,
          startedAt: started,
          finishedAt: started.add(const Duration(milliseconds: 50)),
        ),
      );
      // Let a burst's stream events + an occasional coalesce window
      // elapse, the way a real event loop interleaves with arriving
      // results.
      if (i % 250 == 249) {
        await tester.pump(kDashboardCoalesceWindow * 1.5);
      }
    }
    await store.recordRunCompletion(
      RunSummary(
        runId: 'r1',
        startedAt: started,
        finishedAt: started.add(const Duration(seconds: 5)),
        totalsByStatus: const <TestStatus, int>{},
      ),
    );
    // Trailing-edge flush + final frame.
    await tester.pump(kDashboardCoalesceWindow * 1.5);
    await tester.pump();
    sw.stop();

    expect(tester.takeException(), isNull);
    // Correctness: the final coalesced emission carries every result.
    expect(latestRowCount, total);
    // Coalescing: a handful of rebuilds for 2000 results — never one
    // per result. (8 pump windows + leading edges + final flush.)
    expect(
      rowsRebuilds,
      lessThan(40),
      reason:
          '$rowsRebuilds rows rebuilds for $total streamed results — '
          'coalescing must bound recomputation',
    );
    // Soft, CI-tolerant wall-clock bound for the whole streamed run.
    expect(sw.elapsedMilliseconds, lessThan(3000));

    // Bench numbers for the record:
    // ignore: avoid_print
    print(
      'streaming bench: $total results in ${sw.elapsedMilliseconds} ms, '
      '$rowsRebuilds rows rebuilds',
    );
  });
}
