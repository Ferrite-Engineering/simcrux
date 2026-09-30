// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/result_store.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/services/result_store/in_memory_result_store.dart';

void main() {
  final startedAt = DateTime.utc(2026, 5, 22, 12);

  TestRun makeRun({
    String id = 'run-1',
    List<String>? testIds,
  }) {
    return TestRun(
      id: id,
      startedAt: startedAt,
      testIds: testIds ?? <String>['suite_a/t1', 'suite_a/t2', 'suite_b/t3'],
    );
  }

  TestResult makeResult({
    required String testId,
    String runId = 'run-1',
    TestStatus status = TestStatus.pass,
    Duration runtime = const Duration(seconds: 5),
    int offsetSeconds = 0,
  }) {
    final start = startedAt.add(Duration(seconds: offsetSeconds));
    return TestResult(
      testId: testId,
      runId: runId,
      status: status,
      startedAt: start,
      finishedAt: start.add(runtime),
    );
  }

  group('InMemoryResultStore — basic recording', () {
    test('currentRun emits the initial run on subscribe', () async {
      final store = InMemoryResultStore.forRun(makeRun());
      final first = await store.currentRun.first;
      expect(first.id, equals('run-1'));
      expect(first.results, isEmpty);
    });

    test('recordResult appends to results and bumps currentRun', () async {
      final store = InMemoryResultStore.forRun(makeRun());
      final stream = store.currentRun;
      final iter = StreamIterator(stream);
      await iter.moveNext(); // initial emission

      await store.recordResult(makeResult(testId: 'suite_a/t1'));
      await iter.moveNext();
      expect(iter.current.results, hasLength(1));
      expect(store.recordedCount, equals(1));

      await iter.cancel();
    });

    test('rejects results for the wrong run id', () async {
      final store = InMemoryResultStore.forRun(makeRun());
      expect(
        () => store.recordResult(
          makeResult(testId: 'suite_a/t1', runId: 'bogus'),
        ),
        throwsArgumentError,
      );
    });

    test(
      'currentRun replays the final snapshot to late subscribers '
      '(post-completion re-subscription)',
      () async {
        final store = InMemoryResultStore.forRun(makeRun());
        await store.recordResult(makeResult(testId: 'suite_a/t1'));
        await store.recordRunCompletion(
          RunSummary(
            runId: 'run-1',
            startedAt: startedAt,
            finishedAt: startedAt.add(const Duration(seconds: 1)),
            totalsByStatus: const <TestStatus, int>{},
          ),
        );
        // The dashboard rows/totals StreamProviders re-subscribe when a
        // filter/sort changes after the run finished. A late subscriber
        // must get the final snapshot (then done), not a bare `done` —
        // the regression this guards left the dashboard stuck on the
        // "Loading results…" placeholder forever.
        final replayed = await store.currentRun.toList();
        expect(replayed, hasLength(1));
        expect(replayed.single.results, hasLength(1));
        expect(replayed.single.finishedAt, isNotNull);
      },
    );

    test(
      'currentRun replays the run as it stands to every subscriber, not just '
      'the first (mid-run second and re-subscription)',
      () async {
        final store = InMemoryResultStore.forRun(makeRun());
        await store.recordResult(makeResult(testId: 'suite_a/t1'));

        // The status bar's totals subscribe first and stay subscribed.
        final totals = <TestRun>[];
        final totalsSub = store.currentRun.listen(totals.add);
        addTearDown(totalsSub.cancel);
        await pumpEventQueue();
        expect(totals, hasLength(1));

        // The rows table subscribes second — or re-subscribes after a sort
        // change — while no new result is arriving. It must not wait for
        // one: the regression left the table on "Loading results…" for as
        // long as the running test took.
        final rows = await store.currentRun.first.timeout(
          const Duration(seconds: 1),
        );
        expect(rows.results, hasLength(1));

        final again = await store.currentRun.first.timeout(
          const Duration(seconds: 1),
        );
        expect(again.results, hasLength(1));

        // Both still receive later updates, once each.
        final rowsUpdates = <TestRun>[];
        final rowsSub = store.currentRun.listen(rowsUpdates.add);
        addTearDown(rowsSub.cancel);
        await pumpEventQueue();
        await store.recordResult(makeResult(testId: 'suite_a/t2'));
        await pumpEventQueue();
        expect(totals, hasLength(2));
        expect(rowsUpdates, hasLength(2));
        expect(rowsUpdates.last.results, hasLength(2));
      },
    );

    test('rejects results after recordRunCompletion', () async {
      final store = InMemoryResultStore.forRun(makeRun());
      await store.recordRunCompletion(
        RunSummary(
          runId: 'run-1',
          startedAt: startedAt,
          finishedAt: startedAt.add(const Duration(seconds: 1)),
          totalsByStatus: const <TestStatus, int>{},
        ),
      );
      expect(store.isFinished, isTrue);
      expect(
        () => store.recordResult(makeResult(testId: 'suite_a/t1')),
        throwsStateError,
      );
    });
  });

  group('InMemoryResultStore — indexes', () {
    late InMemoryResultStore store;

    setUp(() {
      store = InMemoryResultStore.forRun(makeRun());
    });

    test('byTestId aggregates results for the same test id', () async {
      await store.recordResult(makeResult(testId: 'suite_a/t1'));
      await store.recordResult(
        makeResult(
          testId: 'suite_a/t1',
          status: TestStatus.fail,
          offsetSeconds: 10,
        ),
      );
      expect(store.indexByTestId['suite_a/t1'], hasLength(2));
    });

    test('byStatus partitions results', () async {
      await store.recordResult(makeResult(testId: 'suite_a/t1'));
      await store.recordResult(
        makeResult(testId: 'suite_a/t2', status: TestStatus.fail),
      );
      await store.recordResult(
        makeResult(testId: 'suite_b/t3', status: TestStatus.fail),
      );
      expect(store.indexByStatus[TestStatus.pass], hasLength(1));
      expect(store.indexByStatus[TestStatus.fail], hasLength(2));
    });

    test(
      'recordResultWithMetadata fills suite and simulator indexes',
      () async {
        await store.recordResultWithMetadata(
          makeResult(testId: 'suite_a/t1'),
          suiteName: 'suite_a',
          simulatorId: 'icarus',
        );
        await store.recordResultWithMetadata(
          makeResult(testId: 'suite_b/t3', status: TestStatus.fail),
          suiteName: 'suite_b',
          simulatorId: 'verilator',
        );
        expect(store.indexBySuite['suite_a'], hasLength(1));
        expect(store.indexBySuite['suite_b'], hasLength(1));
        expect(store.indexBySimulator['icarus'], hasLength(1));
        expect(store.indexBySimulator['verilator'], hasLength(1));
      },
    );

    test(
      'bare recordResult leaves suite and simulator indexes empty',
      () async {
        await store.recordResult(makeResult(testId: 'suite_a/t1'));
        expect(store.indexBySuite, isEmpty);
        expect(store.indexBySimulator, isEmpty);
      },
    );
  });

  group('InMemoryResultStore — queryResults', () {
    late InMemoryResultStore store;

    setUp(() async {
      store = InMemoryResultStore.forRun(makeRun());
      await store.recordResultWithMetadata(
        makeResult(testId: 'suite_a/alu_basic'),
        suiteName: 'suite_a',
        simulatorId: 'icarus',
      );
      await store.recordResultWithMetadata(
        makeResult(
          testId: 'suite_a/alu_overflow',
          status: TestStatus.fail,
          runtime: const Duration(seconds: 30),
          offsetSeconds: 5,
        ),
        suiteName: 'suite_a',
        simulatorId: 'icarus',
      );
      await store.recordResultWithMetadata(
        makeResult(
          testId: 'suite_b/regfile',
          runtime: const Duration(seconds: 90),
          offsetSeconds: 10,
        ),
        suiteName: 'suite_b',
        simulatorId: 'verilator',
      );
    });

    test('returns all when filter is empty', () async {
      final results = await store.queryResults(const ResultQuery()).toList();
      expect(results, hasLength(3));
    });

    test('filters by single status via index', () async {
      final results = await store
          .queryResults(const ResultQuery(status: {TestStatus.fail}))
          .toList();
      expect(results, hasLength(1));
      expect(results.single.testId, equals('suite_a/alu_overflow'));
    });

    test('filters by multiple statuses', () async {
      final results = await store
          .queryResults(
            const ResultQuery(status: {TestStatus.pass, TestStatus.fail}),
          )
          .toList();
      expect(results, hasLength(3));
    });

    test('filters by suite', () async {
      final results = await store
          .queryResults(const ResultQuery(suiteName: 'suite_a'))
          .toList();
      expect(results, hasLength(2));
    });

    test('filters by simulator', () async {
      final results = await store
          .queryResults(const ResultQuery(simulatorId: 'verilator'))
          .toList();
      expect(results.single.testId, equals('suite_b/regfile'));
    });

    test('filters by test id substring', () async {
      final results = await store
          .queryResults(const ResultQuery(testIdSubstring: 'alu'))
          .toList();
      expect(
        results.map((r) => r.testId),
        containsAll(<String>[
          'suite_a/alu_basic',
          'suite_a/alu_overflow',
        ]),
      );
    });

    test('respects runtime bounds', () async {
      final results = await store
          .queryResults(
            const ResultQuery(minRuntime: Duration(seconds: 60)),
          )
          .toList();
      expect(results.single.testId, equals('suite_b/regfile'));
    });

    test('respects limit', () async {
      final results = await store
          .queryResults(const ResultQuery(limit: 1))
          .toList();
      expect(results, hasLength(1));
    });

    test('runId mismatch produces empty stream', () async {
      final results = await store
          .queryResults(const ResultQuery(runId: 'nonexistent'))
          .toList();
      expect(results, isEmpty);
    });
  });

  group('InMemoryResultStore — queryRuns', () {
    test('emits the current run when no time window is set', () async {
      final store = InMemoryResultStore.forRun(makeRun());
      await store.recordResult(makeResult(testId: 'suite_a/t1'));
      final runs = await store.queryRuns(const RunQuery()).toList();
      expect(runs, hasLength(1));
      expect(runs.single.id, equals('run-1'));
    });

    test('honors since lower bound (exclusive of older runs)', () async {
      final store = InMemoryResultStore.forRun(makeRun());
      final since = startedAt.add(const Duration(days: 1));
      final runs = await store.queryRuns(RunQuery(since: since)).toList();
      expect(runs, isEmpty);
    });
  });

  group('InMemoryResultStore — completion', () {
    test(
      'recordRunCompletion publishes finishedAt and closes stream',
      () async {
        final store = InMemoryResultStore.forRun(makeRun());
        final finishedAt = startedAt.add(const Duration(seconds: 60));

        // Subscribe before completion so we receive the final emission.
        final emissions = <TestRun>[];
        final subscription = store.currentRun.listen(emissions.add);

        await store.recordRunCompletion(
          RunSummary(
            runId: 'run-1',
            startedAt: startedAt,
            finishedAt: finishedAt,
            totalsByStatus: const <TestStatus, int>{TestStatus.pass: 3},
          ),
        );
        await subscription.cancel();

        expect(store.summary?.totalsByStatus[TestStatus.pass], equals(3));
        expect(store.isFinished, isTrue);
        expect(emissions.last.finishedAt, equals(finishedAt));
      },
    );
  });
}
