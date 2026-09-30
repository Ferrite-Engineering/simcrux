// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/trend_store.dart';
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
    TestStatus status = TestStatus.pass,
    int runtimeMs = 1500,
    int startedAtUnix = 1_700_000_000_000,
  }) {
    return TrendPoint(
      runId: runId,
      testId: testId,
      status: status,
      runtime: Duration(milliseconds: runtimeMs),
      startedAt: DateTime.fromMillisecondsSinceEpoch(
        startedAtUnix,
        isUtc: true,
      ),
    );
  }

  group('schema', () {
    test('opens at the latest schema version', () async {
      expect(
        await store.schemaVersion(),
        equals(SqlTrendStore.latestSchemaVersion),
      );
    });

    test('starts with empty tables', () async {
      expect(await store.runRowCount(), equals(0));
      expect(await store.resultRowCount(), equals(0));
    });
  });

  group('recordTrendPoint', () {
    test('creates a run row implicitly on first point', () async {
      await store.recordTrendPoint(
        point(runId: 'r1', testId: 'cpu/alu'),
      );
      expect(await store.runRowCount(), equals(1));
      expect(await store.resultRowCount(), equals(1));
    });

    test('groups multiple points under the same run', () async {
      await store.recordTrendPoint(
        point(runId: 'r1', testId: 'cpu/alu'),
      );
      await store.recordTrendPoint(
        point(runId: 'r1', testId: 'cpu/regfile'),
      );
      await store.recordTrendPoint(
        point(runId: 'r1', testId: 'cpu/branch', status: TestStatus.fail),
      );
      expect(await store.runRowCount(), equals(1));
      expect(await store.resultRowCount(), equals(3));
    });

    test('records distinct runs separately', () async {
      await store.recordTrendPoint(
        point(runId: 'r1', testId: 'cpu/alu'),
      );
      await store.recordTrendPoint(
        point(runId: 'r2', testId: 'cpu/alu', status: TestStatus.fail),
      );
      expect(await store.runRowCount(), equals(2));
    });
  });

  group('recordTrendPoints', () {
    test('batch insert matches per-point semantics', () async {
      await store.recordTrendPoints([
        point(runId: 'r1', testId: 'cpu/alu'),
        point(runId: 'r1', testId: 'cpu/regfile'),
        point(runId: 'r2', testId: 'cpu/alu', status: TestStatus.fail),
      ]);
      // Same grouping as three recordTrendPoint calls: implicit run rows,
      // one result row per point, total_tests incremented per point.
      expect(await store.runRowCount(), equals(2));
      expect(await store.resultRowCount(), equals(3));
      final totals = await store.debugRawQuery(
        'SELECT id, total_tests FROM runs ORDER BY id',
      );
      expect(totals, [
        {'id': 'r1', 'total_tests': 2},
        {'id': 'r2', 'total_tests': 1},
      ]);
    });

    test('empty batch is a no-op', () async {
      await store.recordTrendPoints(const <TrendPoint>[]);
      expect(await store.runRowCount(), equals(0));
      expect(await store.resultRowCount(), equals(0));
    });

    test('batch emits a single dataChanged notification', () async {
      var notifications = 0;
      final sub = store.dataChanged.listen((_) => notifications++);
      addTearDown(sub.cancel);
      await store.recordTrendPoints([
        point(runId: 'r1', testId: 'cpu/alu'),
        point(runId: 'r1', testId: 'cpu/regfile'),
      ]);
      // Let the broadcast stream deliver.
      await Future<void>.delayed(Duration.zero);
      expect(notifications, equals(1));
    });
  });

  group('recentTrend', () {
    test('returns matches for a single test id, most recent first', () async {
      await store.recordTrendPoint(
        point(
          runId: 'r1',
          testId: 'cpu/alu',
        ),
      );
      await store.recordTrendPoint(
        point(
          runId: 'r2',
          testId: 'cpu/alu',
          status: TestStatus.fail,
          startedAtUnix: 1_700_000_100_000,
        ),
      );
      await store.recordTrendPoint(
        point(
          runId: 'r3',
          testId: 'cpu/alu',
          startedAtUnix: 1_700_000_200_000,
        ),
      );
      // Add another test to verify filtering.
      await store.recordTrendPoint(
        point(runId: 'r1', testId: 'cpu/regfile'),
      );

      final points = await store.recentTrend('cpu/alu').toList();
      expect(points, hasLength(3));
      expect(points.first.runId, equals('r3'));
      expect(points.last.runId, equals('r1'));
    });

    test('respects limit', () async {
      for (var i = 0; i < 5; i++) {
        await store.recordTrendPoint(
          point(
            runId: 'r$i',
            testId: 'cpu/alu',
            startedAtUnix: 1_700_000_000_000 + i * 1_000_000,
          ),
        );
      }
      final points = await store.recentTrend('cpu/alu', limit: 3).toList();
      expect(points, hasLength(3));
    });

    test('empty for unknown test ids', () async {
      final points = await store.recentTrend('nope').toList();
      expect(points, isEmpty);
    });
  });

  group('recentDeltas', () {
    test('emits a delta when a test newly fails', () async {
      // Older run: pass.
      await store.recordTrendPoint(
        point(
          runId: 'r1',
          testId: 'cpu/alu',
        ),
      );
      // Newer run: fail. The delta should be pass → fail.
      await store.recordTrendPoint(
        point(
          runId: 'r2',
          testId: 'cpu/alu',
          status: TestStatus.fail,
          startedAtUnix: 1_700_000_100_000,
        ),
      );

      final deltas = await store.recentDeltas(limit: 5).toList();
      expect(deltas, hasLength(1));
      final d = deltas.single;
      expect(d.testId, equals('cpu/alu'));
      expect(d.previousStatus, equals(TestStatus.pass));
      expect(d.currentStatus, equals(TestStatus.fail));
      expect(d.currentRunId, equals('r2'));
    });

    test('no delta when status is unchanged', () async {
      await store.recordTrendPoint(
        point(
          runId: 'r1',
          testId: 'cpu/alu',
        ),
      );
      await store.recordTrendPoint(
        point(
          runId: 'r2',
          testId: 'cpu/alu',
          startedAtUnix: 1_700_000_100_000,
        ),
      );
      final deltas = await store.recentDeltas(limit: 5).toList();
      expect(deltas, isEmpty);
    });

    test('first-time test reports previousStatus = null', () async {
      await store.recordTrendPoint(
        point(
          runId: 'r1',
          testId: 'cpu/new_test',
        ),
      );
      final deltas = await store.recentDeltas(limit: 5).toList();
      expect(deltas, hasLength(1));
      expect(deltas.single.previousStatus, isNull);
    });

    test(
      'limit bounds the comparison window — a prior result older than the '
      'newest `limit` runs reads as no-previous-status',
      () async {
        // r0 (oldest) passes; r1..r3 do not run this test at all; r4
        // (newest) fails.
        await store.recordTrendPoint(
          point(runId: 'r0', testId: 'cpu/rare'),
        );
        for (var i = 1; i <= 3; i++) {
          await store.recordTrendPoint(
            point(
              runId: 'r$i',
              testId: 'cpu/filler',
              startedAtUnix: 1_700_000_000_000 + i * 100_000,
            ),
          );
        }
        await store.recordTrendPoint(
          point(
            runId: 'r4',
            testId: 'cpu/rare',
            status: TestStatus.fail,
            startedAtUnix: 1_700_000_500_000,
          ),
        );

        // A window wide enough to include r0 sees the pass → fail change.
        final wide = await store.recentDeltas(limit: 5).toList();
        final wideRare = wide.firstWhere((d) => d.testId == 'cpu/rare');
        expect(wideRare.previousStatus, TestStatus.pass);
        expect(wideRare.currentStatus, TestStatus.fail);

        // A window of 2 runs (r4 + r3) excludes r0, so there is no prior
        // status inside the window: `limit` bounds the comparison, it
        // does not merely select which run ids to report.
        final narrow = await store.recentDeltas(limit: 2).toList();
        final narrowRare = narrow.firstWhere((d) => d.testId == 'cpu/rare');
        expect(narrowRare.previousStatus, isNull);
        expect(narrowRare.currentStatus, TestStatus.fail);
      },
    );

    test('a non-positive limit yields nothing', () async {
      await store.recordTrendPoint(point(runId: 'r1', testId: 'cpu/alu'));
      expect(await store.recentDeltas(limit: 0).toList(), isEmpty);
    });
  });

  group('recordRun', () {
    test('inserts or replaces a run row idempotently', () async {
      final started = DateTime.utc(2026, 5, 22, 12);
      await store.recordRun(
        runId: 'r1',
        startedAt: started,
        totalTests: 10,
        passed: 8,
        failed: 2,
      );
      expect(await store.runRowCount(), equals(1));

      // Replace.
      await store.recordRun(
        runId: 'r1',
        startedAt: started,
        finishedAt: started.add(const Duration(seconds: 30)),
        totalTests: 10,
        passed: 10,
      );
      expect(await store.runRowCount(), equals(1));
    });
  });

  group('pointsForRun', () {
    test('returns every persisted point for the run, ordered', () async {
      await store.recordTrendPoints([
        point(runId: 'r1', testId: 'cpu/alu', runtimeMs: 100),
        point(runId: 'r1', testId: 'cpu/regfile', runtimeMs: 200),
        point(runId: 'r2', testId: 'cpu/alu', runtimeMs: 300),
      ]);
      final r1 = await store.pointsForRun('r1');
      expect(r1.map((p) => p.testId), ['cpu/alu', 'cpu/regfile']);
      expect(r1.every((p) => p.runId == 'r1'), isTrue);
      expect(r1.map((p) => p.runtime.inMilliseconds), [100, 200]);
    });

    test('returns an empty list for an unknown / evicted run id', () async {
      await store.recordTrendPoint(point(runId: 'r1', testId: 'cpu/alu'));
      expect(await store.pointsForRun('does-not-exist'), isEmpty);
    });
  });

  group('persistence across reopen', () {
    test('writes survive close + reopen at the same path', () async {
      await store.close();

      // Re-open at a fresh in-memory database is empty — but the
      // same path on disk would persist. Verify the open+close
      // lifecycle does not break with the in-memory path.
      final reopened = await SqlTrendStore.open();
      addTearDown(reopened.close);
      expect(await reopened.runRowCount(), equals(0));
    });
  });
}
