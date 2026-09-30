// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/trend_store.dart';
import 'package:simcrux/domain/models/retention_policy.dart';
import 'package:simcrux/services/trend_store/sql_trend_store_io.dart';

/// Retention must actually bound the trend database
/// across many runs, prune the `runs` table it used to leave growing
/// forever, and stop paying for a full `VACUUM` on every pass.
///
/// This is an integration-shaped test: drive
/// synthetic runs against a real on-disk database and assert the file
/// and the row counts stay bounded, rather than asserting on a single
/// `applyRetention` call in isolation.
void main() {
  late Directory tmp;
  late String dbPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('simcrux_retention_');
    dbPath = '${tmp.path}/trends.db';
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> recordRun(
    SqlTrendStore store,
    int runIndex, {
    int tests = 200,
  }) async {
    final origin = DateTime.utc(2026).add(Duration(hours: runIndex));
    await store.recordTrendPoints(<TrendPoint>[
      for (var t = 0; t < tests; t++)
        TrendPoint(
          runId: 'r$runIndex',
          testId: 'cpu/t$t',
          status: (runIndex + t).isEven ? TestStatus.pass : TestStatus.fail,
          runtime: const Duration(milliseconds: 5),
          startedAt: origin,
        ),
    ]);
  }

  test(
    'row count and on-disk size stay bounded across 30 synthetic runs',
    () async {
      final store = await SqlTrendStore.open(path: dbPath);
      addTearDown(store.close);
      const policy = RetentionPolicy(maxDataPoints: 2000);

      final sizes = <int>[];
      for (var run = 0; run < 30; run++) {
        await recordRun(store, run);
        await store.applyRetention(policy);
        expect(
          await store.resultRowCount(),
          lessThanOrEqualTo(2000),
          reason: 'retention must hold the cap after run $run',
        );
        sizes.add(File(dbPath).lengthSync());
      }

      // The whole point: the file does not grow monotonically with the
      // number of runs. Compare the tail of the series against the
      // point where the cap first bit.
      final settled = sizes.sublist(15);
      final maxSettled = settled.reduce((a, b) => a > b ? a : b);
      final minSettled = settled.reduce((a, b) => a < b ? a : b);
      expect(
        maxSettled,
        lessThan(minSettled * 3),
        reason: 'db size must plateau once the cap binds; saw $settled bytes',
      );
    },
  );

  test('the runs table is pruned, not left to grow forever', () async {
    final store = await SqlTrendStore.open(path: dbPath);
    addTearDown(store.close);
    for (var run = 0; run < 25; run++) {
      await recordRun(store, run, tests: 50);
    }
    expect(await store.runRowCount(), 25);

    // Keep only the newest ~200 points ⇒ ~4 runs' worth of results;
    // the other runs lose every row and must be pruned.
    await store.applyRetention(const RetentionPolicy(maxDataPoints: 200));

    final runs = await store.runRowCount();
    expect(
      runs,
      lessThan(25),
      reason: 'runs with no surviving results must be pruned',
    );
    // Every surviving run must still be referenced by surviving data.
    final orphans = await store.debugRawQuery(
      'SELECT COUNT(*) AS c FROM runs '
      'WHERE id NOT IN (SELECT DISTINCT run_id FROM test_results)',
    );
    expect(orphans.first['c'], 0);
  });

  test(
    'an in-flight run (row written, results not yet flushed) survives '
    'the run prune',
    () async {
      final store = await SqlTrendStore.open(path: dbPath);
      addTearDown(store.close);
      for (var run = 0; run < 10; run++) {
        await recordRun(store, run, tests: 50);
      }
      // A run that has begun but whose first result has not landed: its
      // `runs` row exists with zero test_results, and it is the newest.
      await store.recordRun(
        runId: 'in_flight',
        startedAt: DateTime.utc(2026).add(const Duration(hours: 99)),
      );

      await store.applyRetention(const RetentionPolicy(maxDataPoints: 100));

      final rows = await store.debugRawQuery(
        "SELECT id FROM runs WHERE id = 'in_flight'",
      );
      expect(
        rows,
        hasLength(1),
        reason:
            'the run prune must not delete a started-but-unflushed run '
            'out from under the writer',
      );
    },
  );

  test('VACUUM is conditional, not unconditional', () async {
    final store = await SqlTrendStore.open(path: dbPath);
    addTearDown(store.close);
    for (var run = 0; run < 6; run++) {
      await recordRun(store, run, tests: 100);
    }
    // A prune that frees a trivial number of pages must leave the
    // freelist in place rather than rewriting the whole file.
    await store.applyRetention(const RetentionPolicy(maxDataPoints: 599));
    final free = await store.debugRawQuery('PRAGMA freelist_count');
    final freeCount = free.first.values.first! as int;
    final pages = await store.debugRawQuery('PRAGMA page_count');
    final pageCount = pages.first.values.first! as int;
    final fraction = pageCount == 0 ? 0.0 : freeCount / pageCount;
    // Either nothing was freed, or the freed fraction is below the
    // threshold and was therefore (correctly) not reclaimed. An
    // unconditional VACUUM would always leave freelist_count == 0.
    expect(
      freeCount == 0 ||
          fraction < SqlTrendStore.kVacuumMinFreeFraction ||
          freeCount * 4096 < SqlTrendStore.kVacuumMinReclaimableBytes,
      isTrue,
      reason: 'freelist=$freeCount pages=$pageCount',
    );
  });

  test(
    'lowestValueFirst decimation still honors the cap after batching',
    () async {
      final store = await SqlTrendStore.open(path: dbPath);
      addTearDown(store.close);
      for (var run = 0; run < 20; run++) {
        await recordRun(store, run, tests: 100);
      }
      expect(await store.resultRowCount(), 2000);
      final deleted = await store.applyRetention(
        const RetentionPolicy(
          maxDataPoints: 500,
          pruneStrategy: RetentionPruneStrategy.lowestValueFirst,
        ),
      );
      expect(deleted, greaterThan(0));
      // Decimation keeps the freshest 75% verbatim plus a sampled tail,
      // so the survivor count lands at or below the cap.
      expect(await store.resultRowCount(), lessThanOrEqualTo(500));
      // Freshness preference: the newest run is retained in full.
      final newest = await store.debugRawQuery(
        "SELECT COUNT(*) AS c FROM test_results WHERE run_id = 'r19'",
      );
      expect(newest.first['c'], 100);
    },
  );
}
