// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/trend_store.dart';
import 'package:simcrux/domain/models/trend_aggregate.dart';
import 'package:simcrux/services/trend_store/sql_trend_store_io.dart';

/// Wall-clock companion to `trend_query_index_test.dart`. The
/// deterministic index-plan/schema guard lives there and runs on every
/// `flutter test`; this file isolates the raw elapsed-time measurement,
/// which is machine-dependent and gated behind `RUN_BENCHMARKS` so it never
/// runs on a shared CI runner outside the nightly perf job.
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
    'per-test aggregate over a 10k-run store stays under budget',
    () async {
      final sw = Stopwatch()..start();
      final out = await store.queryAggregates(
        key: const TrendAggregateKey.perTest('cpu_unit/t7'),
        bucketSize: const Duration(days: 1),
      );
      sw.stop();
      expect(out, isNotEmpty);
      // Soft budget; documented CI tolerance.
      expect(
        sw.elapsedMilliseconds,
        lessThan(200),
        reason: 'aggregate must stay interactive',
      );
    },
    skip: const bool.fromEnvironment('RUN_BENCHMARKS')
        ? false
        : 'perf benchmark gated — pass --dart-define=RUN_BENCHMARKS=true',
  );
}
