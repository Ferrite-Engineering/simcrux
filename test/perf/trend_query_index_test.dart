// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/trend_store.dart';
import 'package:simcrux/services/trend_store/sql_trend_store_io.dart';

/// The flaky-detection trend aggregate over a 10k-run store must be
/// served by an index (no table scan / temp-sort). Deterministic, always-on
/// guard: the query plan and schema are machine-independent, unlike the
/// companion wall-clock budget in `trend_query_wallclock_bench_test.dart`
/// (nightly-only).
///
/// MUTATION: dropping the composite `(test_name, started_at)` index
/// (migration v2) makes the planner fall back to a sort and stop using
/// `idx_results_test_started` — the plan assertion goes red.
void main() {
  late SqlTrendStore store;

  setUp(() async {
    store = await SqlTrendStore.open();
    // 200 tests × 50 runs = 10k rows, time-ordered.
    final origin = DateTime.utc(2026);
    for (var run = 0; run < 50; run++) {
      for (var t = 0; t < 200; t++) {
        await store.recordTrendPoint(
          TrendPoint(
            runId: 'r$run',
            testId: 'cpu_unit/t$t',
            status: (run + t).isEven ? TestStatus.pass : TestStatus.fail,
            runtime: const Duration(milliseconds: 5),
            startedAt: origin.add(Duration(hours: run)),
          ),
        );
      }
    }
  });
  tearDown(() => store.close());

  test(
    'the aggregate is served by the composite index — no SCAN, no sort',
    () async {
      final plan = await store.debugRawQuery(
        'EXPLAIN QUERY PLAN '
        'SELECT status, runtime_ms, started_at FROM test_results '
        'WHERE test_name = ? ORDER BY started_at ASC',
        <Object?>['cpu_unit/t7'],
      );
      final detail = plan.map((r) => '${r['detail']}').join(' | ');
      expect(detail, isNot(contains('SCAN')), reason: detail);
      // The composite (test_name, started_at) index covers both the filter
      // and the ordering, so the planner uses it and needs no temp B-tree.
      expect(detail, contains('idx_results_test_started'), reason: detail);
      expect(detail, isNot(contains('TEMP B-TREE')), reason: detail);
    },
  );

  test('the supporting composite index is present in the schema', () async {
    final rows = await store.debugRawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'index' "
      "AND name = 'idx_results_test_started'",
    );
    expect(rows, hasLength(1));
  });
}
