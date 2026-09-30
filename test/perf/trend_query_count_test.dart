// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/trend_store.dart';
import 'package:simcrux/services/trend_store/sql_trend_store_io.dart';

/// The trend store's hot read paths must cost a
/// number of SQL statements that does **not** scale with the number of
/// tests.
///
/// These are query-count guards rather than wall-clock budgets on
/// purpose. The defect they lock down is algorithmic: `recentDeltas`
/// issued one `SELECT … LIMIT 1` per test in the newest run, and the
/// flaky-retry prime issued one `recentTrend` per spec. Both are
/// invisible on a 10-test fixture and catastrophic at 10k, and both
/// queue behind the single sqflite worker — a wall-clock assertion
/// large enough to be CI-stable would not catch a regression back to
/// N+1 until it was already shipping.
///
/// MUTATION check: reverting `recentDeltas` to the per-test prior-status
/// lookup makes the first test here report ~1000 queries instead of 1.
void main() {
  late SqlTrendStore store;

  const testCount = 1000;
  const runCount = 6;

  setUp(() async {
    store = await SqlTrendStore.open();
    final origin = DateTime.utc(2026);
    for (var run = 0; run < runCount; run++) {
      await store.recordTrendPoints(<TrendPoint>[
        for (var t = 0; t < testCount; t++)
          TrendPoint(
            runId: 'r$run',
            testId: 'cpu_unit/t$t',
            // Every test alternates status per run, so every test in the
            // newest run is a genuine delta — the worst case for the
            // old per-test lookup.
            status: (run + t).isEven ? TestStatus.pass : TestStatus.fail,
            runtime: const Duration(milliseconds: 5),
            startedAt: origin.add(Duration(hours: run)),
          ),
      ]);
    }
  });
  tearDown(() => store.close());

  test(
    'recentDeltas costs exactly one query regardless of test count',
    () async {
      store.resetDebugQueryCount();
      final deltas = await store.recentDeltas(limit: runCount).toList();
      expect(
        store.debugQueryCount,
        1,
        reason:
            'recentDeltas must resolve prior status with one windowed '
            'query, not one lookup per test',
      );
      // Correctness alongside the cost guard: every test alternates, so
      // every test in the newest run is a delta.
      expect(deltas, hasLength(testCount));
    },
  );

  test('recentTrendsFor costs O(chunks), not O(tests)', () async {
    final ids = <String>[for (var t = 0; t < testCount; t++) 'cpu_unit/t$t'];
    store.resetDebugQueryCount();
    final trends = await store.recentTrendsFor(ids, limit: 5);
    // 1000 ids at 500 placeholders per statement ⇒ 2 queries.
    expect(
      store.debugQueryCount,
      lessThanOrEqualTo(3),
      reason: 'bulk trend fetch must chunk, not fan out per test',
    );
    expect(trends, hasLength(testCount));
    expect(trends['cpu_unit/t0'], hasLength(5));
  });

  test('distinctTestIds costs one query and enumerates every test', () async {
    store.resetDebugQueryCount();
    final ids = await store.distinctTestIds(runWindow: runCount);
    expect(store.debugQueryCount, 1);
    expect(ids, hasLength(testCount));
  });

  test(
    'recentTrendsFor agrees with per-test recentTrend (equivalence)',
    () async {
      final ids = <String>['cpu_unit/t0', 'cpu_unit/t17', 'cpu_unit/t999'];
      final bulk = await store.recentTrendsFor(ids, limit: 4);
      for (final id in ids) {
        final single = await store.recentTrend(id, limit: 4).toList();
        final bulkPoints = bulk[id]!;
        expect(bulkPoints, hasLength(single.length), reason: id);
        for (var i = 0; i < single.length; i++) {
          expect(bulkPoints[i].runId, single[i].runId, reason: '$id[$i]');
          expect(bulkPoints[i].status, single[i].status, reason: '$id[$i]');
          expect(
            bulkPoints[i].startedAt,
            single[i].startedAt,
            reason: '$id[$i]',
          );
        }
      }
    },
  );

  test(
    'the recent-runs window is served by the runs(started_at) index',
    () async {
      final plan = await store.debugRawQuery(
        'EXPLAIN QUERY PLAN '
        'SELECT id FROM runs ORDER BY started_at DESC LIMIT 10',
      );
      final detail = plan.map((r) => '${r['detail']}').join(' | ');
      expect(detail, contains('idx_runs_started'), reason: detail);
      expect(detail, isNot(contains('TEMP B-TREE')), reason: detail);
    },
  );
}
