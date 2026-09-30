// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Tests for the extended SqlTrendStore surface:
// queryDataPoints, queryAggregates, applyRetention, storageStats,
// and the dataChanged stream.
//
// The existing sql_trend_store_test.dart file covers the narrow
// recordTrendPoint / recentTrend / recentDeltas surface.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/trend_store.dart';
import 'package:simcrux/domain/models/retention_policy.dart';
import 'package:simcrux/domain/models/trend_aggregate.dart';
import 'package:simcrux/services/trend_store/sql_trend_store_io.dart';

void main() {
  late SqlTrendStore store;

  setUp(() async {
    store = await SqlTrendStore.open();
  });

  tearDown(() async {
    if (store.isOpen) {
      await store.close();
    }
  });

  TrendPoint point({
    required String runId,
    required String testId,
    required DateTime startedAt,
    TestStatus status = TestStatus.pass,
    int runtimeMs = 1500,
    String? waveformPath,
    String? suiteName,
  }) {
    return TrendPoint(
      runId: runId,
      testId: testId,
      status: status,
      runtime: Duration(milliseconds: runtimeMs),
      startedAt: startedAt,
      waveformPath: waveformPath,
      suiteName: suiteName,
    );
  }

  group('queryDataPoints', () {
    test('returns empty list when nothing was ingested', () async {
      final out = await store.queryDataPoints(testId: 'nope');
      expect(out, isEmpty);
    });

    test('filters by testId', () async {
      final t0 = DateTime.utc(2026, 5, 2, 10);
      await store.recordTrendPoint(
        point(runId: 'r1', testId: 'a', startedAt: t0),
      );
      await store.recordTrendPoint(
        point(runId: 'r1', testId: 'b', startedAt: t0),
      );
      await store.recordTrendPoint(
        point(
          runId: 'r2',
          testId: 'a',
          startedAt: t0.add(const Duration(hours: 1)),
        ),
      );
      final aOnly = await store.queryDataPoints(testId: 'a');
      expect(aOnly.length, 2);
      expect(aOnly.every((p) => p.testId == 'a'), isTrue);
    });

    test('orders newest first', () async {
      final t0 = DateTime.utc(2026, 5, 2, 10);
      await store.recordTrendPoint(
        point(runId: 'r1', testId: 'a', startedAt: t0),
      );
      await store.recordTrendPoint(
        point(
          runId: 'r2',
          testId: 'a',
          startedAt: t0.add(const Duration(hours: 1)),
        ),
      );
      await store.recordTrendPoint(
        point(
          runId: 'r3',
          testId: 'a',
          startedAt: t0.add(const Duration(hours: 2)),
        ),
      );
      final out = await store.queryDataPoints(testId: 'a');
      expect(out.map((p) => p.runId).toList(), ['r3', 'r2', 'r1']);
    });

    test('respects since filter (UTC)', () async {
      final t0 = DateTime.utc(2026, 5, 2, 10);
      await store.recordTrendPoint(
        point(runId: 'r1', testId: 'a', startedAt: t0),
      );
      await store.recordTrendPoint(
        point(
          runId: 'r2',
          testId: 'a',
          startedAt: t0.add(const Duration(hours: 5)),
        ),
      );
      final out = await store.queryDataPoints(
        testId: 'a',
        since: t0.add(const Duration(hours: 1)),
      );
      expect(out.length, 1);
      expect(out.single.runId, 'r2');
    });

    test('respects limit + offset', () async {
      final t0 = DateTime.utc(2026, 5, 2, 10);
      for (var i = 0; i < 5; i++) {
        await store.recordTrendPoint(
          point(
            runId: 'r$i',
            testId: 'a',
            startedAt: t0.add(Duration(hours: i)),
          ),
        );
      }
      final firstTwo = await store.queryDataPoints(testId: 'a', limit: 2);
      expect(firstTwo.length, 2);
      // Newest two: r4, r3
      expect(firstTwo.map((p) => p.runId).toList(), ['r4', 'r3']);

      final nextTwo = await store.queryDataPoints(
        testId: 'a',
        limit: 2,
        offset: 2,
      );
      expect(nextTwo.map((p) => p.runId).toList(), ['r2', 'r1']);
    });
  });

  group('queryAggregates', () {
    test('returns empty list when store is empty', () async {
      final out = await store.queryAggregates(
        key: const TrendAggregateKey.global(),
        bucketSize: const Duration(days: 1),
      );
      expect(out, isEmpty);
    });

    test('rejects non-positive bucket size', () async {
      await expectLater(
        () => store.queryAggregates(
          key: const TrendAggregateKey.global(),
          bucketSize: Duration.zero,
        ),
        throwsArgumentError,
      );
    });

    test('groups data points by bucket index', () async {
      final origin = DateTime.utc(2026, 5, 2);
      // 3 runs in day-1, 1 run in day-2.
      for (var i = 0; i < 3; i++) {
        await store.recordTrendPoint(
          point(
            runId: 'r$i',
            testId: 'a',
            startedAt: origin.add(Duration(hours: i)),
          ),
        );
      }
      await store.recordTrendPoint(
        point(
          runId: 'r3',
          testId: 'a',
          startedAt: origin.add(const Duration(days: 1, hours: 1)),
          status: TestStatus.fail,
        ),
      );

      final out = await store.queryAggregates(
        key: const TrendAggregateKey.global(),
        bucketSize: const Duration(days: 1),
        since: origin,
      );
      expect(out.length, 2);
      // Day 1 — three passes.
      expect(out[0].totalRuns, 3);
      expect(out[0].passCount, 3);
      expect(out[0].failCount, 0);
      // Day 2 — one fail.
      expect(out[1].totalRuns, 1);
      expect(out[1].failCount, 1);
      expect(out[1].passCount, 0);
    });

    test('computes runtime percentiles inside each bucket', () async {
      final origin = DateTime.utc(2026, 5, 2);
      final runtimes = [100, 200, 300, 400, 500];
      for (var i = 0; i < runtimes.length; i++) {
        await store.recordTrendPoint(
          point(
            runId: 'r$i',
            testId: 'a',
            startedAt: origin.add(Duration(minutes: i)),
            runtimeMs: runtimes[i],
          ),
        );
      }
      final out = await store.queryAggregates(
        key: const TrendAggregateKey.global(),
        bucketSize: const Duration(hours: 1),
        since: origin,
      );
      expect(out.length, 1);
      // nearest-rank: p50 = idx ceil(.5 * 5) - 1 = 2 → 300; p95 = 4 → 500.
      expect(out.single.p50RuntimeMs, 300);
      expect(out.single.p95RuntimeMs, 500);
      expect(out.single.p99RuntimeMs, 500);
    });

    test('filters by per-test key', () async {
      final origin = DateTime.utc(2026, 5, 2);
      await store.recordTrendPoint(
        point(runId: 'r1', testId: 'a', startedAt: origin),
      );
      await store.recordTrendPoint(
        point(runId: 'r1', testId: 'b', startedAt: origin),
      );
      final aOnly = await store.queryAggregates(
        key: const TrendAggregateKey.perTest('a'),
        bucketSize: const Duration(days: 1),
      );
      expect(aOnly.single.totalRuns, 1);
    });

    test('filters by per-suite key, from both ingest paths', () async {
      // The per-suite trend view reads the local store through this key. The
      // suite used to be written as '' for every point, so the view was
      // empty on any seat whose history lives here.
      final origin = DateTime.utc(2026, 5, 2);
      await store.recordTrendPoint(
        point(
          runId: 'r1',
          testId: 'uart/tx',
          startedAt: origin,
          suiteName: 'uart',
        ),
      );
      await store.recordTrendPoints([
        point(
          runId: 'r1',
          testId: 'uart/rx',
          startedAt: origin,
          status: TestStatus.fail,
          suiteName: 'uart',
        ),
        point(
          runId: 'r1',
          testId: 'soc/boot',
          startedAt: origin,
          suiteName: 'soc',
        ),
        // A point with no suite belongs to no suite's view.
        point(runId: 'r1', testId: 'loose', startedAt: origin),
      ]);

      final uart = await store.queryAggregates(
        key: const TrendAggregateKey.perSuite('uart'),
        bucketSize: const Duration(days: 1),
      );
      expect(uart.single.totalRuns, 2);
      expect(uart.single.passCount, 1);
      expect(uart.single.failCount, 1);

      final soc = await store.queryAggregates(
        key: const TrendAggregateKey.perSuite('soc'),
        bucketSize: const Duration(days: 1),
      );
      expect(soc.single.totalRuns, 1);

      final uartPoints = await store.queryDataPoints(suiteId: 'uart');
      expect(
        uartPoints.map((p) => p.testId),
        unorderedEquals(<String>['uart/tx', 'uart/rx']),
      );
    });

    test('classifies skipped / cancelled into skipCount', () async {
      final origin = DateTime.utc(2026, 5, 2);
      await store.recordTrendPoint(
        point(
          runId: 'r1',
          testId: 'a',
          startedAt: origin,
          status: TestStatus.skipped,
        ),
      );
      await store.recordTrendPoint(
        point(
          runId: 'r2',
          testId: 'a',
          startedAt: origin,
          status: TestStatus.cancelled,
        ),
      );
      final out = await store.queryAggregates(
        key: const TrendAggregateKey.global(),
        bucketSize: const Duration(days: 1),
        since: origin,
      );
      expect(out.single.skipCount, 2);
      expect(out.single.passCount, 0);
      expect(out.single.failCount, 0);
    });
  });

  group('applyRetention', () {
    test('unlimited policy is a no-op', () async {
      final origin = DateTime.utc(2026, 5, 2);
      await store.recordTrendPoint(
        point(runId: 'r1', testId: 'a', startedAt: origin),
      );
      final deleted = await store.applyRetention(RetentionPolicy.unlimited);
      expect(deleted, 0);
      expect(await store.resultRowCount(), 1);
    });

    test('maxAgeDays deletes rows older than the cutoff', () async {
      final now = DateTime.now().toUtc();
      await store.recordTrendPoint(
        point(
          runId: 'r1',
          testId: 'a',
          startedAt: now.subtract(const Duration(days: 60)),
        ),
      );
      await store.recordTrendPoint(
        point(
          runId: 'r2',
          testId: 'a',
          startedAt: now.subtract(const Duration(days: 1)),
        ),
      );
      final deleted = await store.applyRetention(
        const RetentionPolicy(maxAgeDays: 30),
      );
      expect(deleted, 1);
      final remaining = await store.queryDataPoints(testId: 'a', limit: 10);
      expect(remaining.length, 1);
      expect(remaining.single.runId, 'r2');
    });

    test('maxDataPoints + oldestFirst deletes the oldest rows', () async {
      final origin = DateTime.utc(2026, 5, 2);
      for (var i = 0; i < 10; i++) {
        await store.recordTrendPoint(
          point(
            runId: 'r$i',
            testId: 'a',
            startedAt: origin.add(Duration(minutes: i)),
          ),
        );
      }
      final deleted = await store.applyRetention(
        const RetentionPolicy(maxDataPoints: 4),
      );
      expect(deleted, 6);
      expect(await store.resultRowCount(), 4);
      final remaining = await store.queryDataPoints(testId: 'a', limit: 100);
      // Newest 4 are r6..r9.
      expect(
        remaining.map((p) => p.runId).toList(),
        ['r9', 'r8', 'r7', 'r6'],
      );
    });

    test('zero deletions when count is below cap', () async {
      await store.recordTrendPoint(
        point(
          runId: 'r1',
          testId: 'a',
          startedAt: DateTime.now().toUtc(),
        ),
      );
      final deleted = await store.applyRetention(
        const RetentionPolicy(maxDataPoints: 100),
      );
      expect(deleted, 0);
    });
  });

  group('waveformPathsBeforeRecentRuns', () {
    // Regression: the ingest path used to drop `TrendPoint.waveformPath` on
    // the floor — `_insertTrendPoint` never bound the `waveform_path` column,
    // so the sweep's `WHERE waveform_path IS NOT NULL` could never match and
    // `maxWaveformRuns` was a silent no-op. The dumps are the part that
    // actually fills a disk, so an Enterprise admin who capped waveform
    // retention got a policy that reported itself honoured and swept nothing.
    test('a recorded dump path comes back out of the store', () async {
      await store.recordTrendPoint(
        point(
          runId: 'r1',
          testId: 'cpu/alu',
          startedAt: DateTime.utc(2026, 5, 2),
          waveformPath: '/work/r1/cpu_alu/dump.fst',
        ),
      );
      expect(
        await store.waveformPathsBeforeRecentRuns(0),
        <String>['/work/r1/cpu_alu/dump.fst'],
      );
    });

    test('the batch ingest path persists it too', () async {
      await store.recordTrendPoints(<TrendPoint>[
        point(
          runId: 'r1',
          testId: 'cpu/alu',
          startedAt: DateTime.utc(2026, 5, 2),
          waveformPath: '/work/r1/cpu_alu/dump.fst',
        ),
        point(
          runId: 'r1',
          testId: 'cpu/regfile',
          startedAt: DateTime.utc(2026, 5, 2),
        ),
      ]);
      expect(
        await store.waveformPathsBeforeRecentRuns(0),
        <String>['/work/r1/cpu_alu/dump.fst'],
      );
    });

    test(
      'keepRuns spares the newest runs and yields the older dumps',
      () async {
        final origin = DateTime.utc(2026, 5, 2);
        for (var i = 0; i < 3; i++) {
          await store.recordTrendPoint(
            point(
              runId: 'r$i',
              testId: 'cpu/alu',
              startedAt: origin.add(Duration(minutes: i)),
              waveformPath: '/work/r$i/dump.fst',
            ),
          );
        }
        expect(
          await store.waveformPathsBeforeRecentRuns(1),
          <String>['/work/r0/dump.fst', '/work/r1/dump.fst'],
        );
      },
    );

    test(
      'rows recorded without a dump are never offered for sweeping',
      () async {
        await store.recordTrendPoint(
          point(
            runId: 'r1',
            testId: 'cpu/alu',
            startedAt: DateTime.utc(2026, 5, 2),
          ),
        );
        expect(await store.waveformPathsBeforeRecentRuns(0), isEmpty);
      },
    );

    test('forgetWaveformPaths clears the persisted path', () async {
      await store.recordTrendPoint(
        point(
          runId: 'r1',
          testId: 'cpu/alu',
          startedAt: DateTime.utc(2026, 5, 2),
          waveformPath: '/work/r1/dump.fst',
        ),
      );
      await store.forgetWaveformPaths(<String>['/work/r1/dump.fst']);
      expect(await store.waveformPathsBeforeRecentRuns(0), isEmpty);
      // The result row itself outlives its dump.
      expect(await store.resultRowCount(), 1);
    });
  });

  group('storageStats', () {
    test('empty store reports zero counts', () async {
      final stats = await store.storageStats();
      expect(stats.dataPointCount, 0);
      expect(stats.runCount, 0);
      expect(stats.oldestPointAt, isNull);
      expect(stats.newestPointAt, isNull);
    });

    test('counts and span reflect ingested rows', () async {
      final t0 = DateTime.utc(2026, 5, 2);
      await store.recordTrendPoint(
        point(runId: 'r1', testId: 'a', startedAt: t0),
      );
      await store.recordTrendPoint(
        point(
          runId: 'r2',
          testId: 'a',
          startedAt: t0.add(const Duration(days: 1)),
        ),
      );
      final stats = await store.storageStats();
      expect(stats.dataPointCount, 2);
      expect(stats.runCount, 2);
      expect(stats.oldestPointAt, t0);
      expect(stats.newestPointAt, t0.add(const Duration(days: 1)));
    });
  });

  group('dataChanged stream', () {
    test('emits on ingestion', () async {
      final completer = Completer<void>();
      final sub = store.dataChanged.listen((_) {
        if (!completer.isCompleted) completer.complete();
      });
      await store.recordTrendPoint(
        point(
          runId: 'r1',
          testId: 'a',
          startedAt: DateTime.now().toUtc(),
        ),
      );
      await completer.future.timeout(const Duration(seconds: 1));
      await sub.cancel();
    });

    test('emits on retention pruning', () async {
      final t0 = DateTime.now().toUtc();
      await store.recordTrendPoint(
        point(
          runId: 'r1',
          testId: 'a',
          startedAt: t0.subtract(const Duration(days: 60)),
        ),
      );
      // Now subscribe — and ensure a prune triggers an event.
      final completer = Completer<void>();
      final sub = store.dataChanged.listen((_) {
        if (!completer.isCompleted) completer.complete();
      });
      await store.applyRetention(const RetentionPolicy(maxAgeDays: 30));
      await completer.future.timeout(const Duration(seconds: 1));
      await sub.cancel();
    });

    test('no emit on retention when nothing was deleted', () async {
      var emitted = 0;
      final sub = store.dataChanged.listen((_) => emitted++);
      await store.applyRetention(const RetentionPolicy(maxAgeDays: 30));
      // Give any (unwanted) emission a chance to land before asserting
      // its absence.
      await pumpEventQueue(times: 10);
      expect(emitted, 0);
      await sub.cancel();
    });
  });
}
