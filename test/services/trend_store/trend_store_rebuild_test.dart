// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/trend_aggregate.dart';
import 'package:simcrux/domain/models/trend_store_rebuild_report.dart';
import 'package:simcrux/services/result_store/streaming_results_writer.dart';
import 'package:simcrux/services/trend_store/sql_trend_store_io.dart';
import 'package:simcrux/services/trend_store/trend_store_rebuild.dart';

/// The trend store's rebuild from the `results.ndjson` files runs leave behind.
///
/// The round trip is driven end to end through the real producer: a
/// [StreamingResultsWriter] writes a real `results.ndjson` to a real temp
/// directory, and the rebuilder reads it back into a real SQLite store. A test
/// that hand-wrote the NDJSON would pass forever after the writer's format
/// changed underneath it — and the writer's format is the entire premise of
/// this feature.
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('simcrux_rebuild_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  DashboardRow row(
    String testId, {
    required TestStatus status,
    required DateTime startedAt,
    required Duration runtime,
    String runId = 'run-1',
    bool didExecute = true,
    String? waveformPath,
    String suiteName = 'unit',
  }) => DashboardRow(
    result: TestResult(
      testId: testId,
      runId: runId,
      status: status,
      startedAt: startedAt,
      finishedAt: startedAt.add(runtime),
      didExecute: didExecute,
      waveformPath: waveformPath,
    ),
    suiteName: suiteName,
    simulatorId: 'icarus',
    testName: testId,
  );

  /// Writes a real archive and returns its path.
  Future<String> writeArchive({
    required String name,
    required String runId,
    required List<DashboardRow> rows,
    DateTime? startedAt,
    bool complete = true,
    bool writeMeta = true,
  }) async {
    final path = '${tmp.path}/$name';
    final writer = StreamingResultsWriter(resultsPath: path);
    if (writeMeta) {
      await writer.start(
        runId: runId,
        startedAt: startedAt ?? DateTime.utc(2026, 6, 10),
      );
    } else {
      // A crash before the first flush: the file exists with result lines but
      // no `meta` header, so nothing attributes its rows to a run.
      await writer.start(runId: runId, startedAt: DateTime.utc(2026, 6, 10));
    }
    for (final r in rows) {
      await writer.recordRow(r);
    }
    if (complete) {
      await writer.recordRunCompletion(
        finishedAt: DateTime.utc(2026, 6, 10, 0, 5),
      );
    } else {
      await writer.abortWithoutSummary();
    }
    if (!writeMeta) {
      final lines = File(path).readAsLinesSync()
        ..removeWhere((l) => l.contains('"type":"meta"'));
      File(path).writeAsStringSync('${lines.join('\n')}\n');
    }
    return path;
  }

  test('round trip: every trend-point field survives the archive', () async {
    final started = DateTime.utc(2026, 6, 10, 12, 30, 15);
    final archive = await writeArchive(
      name: 'results.ndjson',
      runId: 'run-1',
      rows: [
        row(
          'alu/add',
          status: TestStatus.pass,
          startedAt: started,
          runtime: const Duration(milliseconds: 1250),
        ),
        row(
          'alu/sub',
          status: TestStatus.fail,
          startedAt: started.add(const Duration(seconds: 2)),
          runtime: const Duration(milliseconds: 87),
        ),
      ],
    );
    final store = await SqlTrendStore.open(path: '${tmp.path}/trends.db');
    addTearDown(store.close);

    final report = await const TrendStoreRebuilder().rebuild(
      store: store,
      archivePaths: [archive],
    );

    expect(report.runsRecovered, 1);
    expect(report.pointsRecovered, 2);
    expect(report.archives.single.outcome, TrendStoreArchiveOutcome.recovered);

    final points = await store.pointsForRun('run-1');
    expect(points, hasLength(2));
    final add = points.firstWhere((p) => p.testId == 'alu/add');
    expect(add.runId, 'run-1');
    expect(add.status, TestStatus.pass);
    expect(add.runtime, const Duration(milliseconds: 1250));
    expect(add.startedAt, started);
    final sub = points.firstWhere((p) => p.testId == 'alu/sub');
    expect(sub.status, TestStatus.fail);
    expect(sub.runtime, const Duration(milliseconds: 87));
  });

  test('a replayed suite is what the per-suite view finds', () async {
    // The per-suite trend view filters the store by suite. A rebuild that
    // dropped the archive's `suite` would restore runs no suite's chart can
    // show.
    final started = DateTime.utc(2026, 6, 10, 12, 30, 15);
    final archive = await writeArchive(
      name: 'results.ndjson',
      runId: 'run-1',
      rows: [
        row(
          'alu/add',
          status: TestStatus.pass,
          startedAt: started,
          runtime: const Duration(milliseconds: 1250),
          suiteName: 'alu',
        ),
        row(
          'alu/sub',
          status: TestStatus.fail,
          startedAt: started.add(const Duration(seconds: 2)),
          runtime: const Duration(milliseconds: 87),
          suiteName: 'alu',
        ),
        row(
          'soc/boot',
          status: TestStatus.pass,
          startedAt: started.add(const Duration(seconds: 3)),
          runtime: const Duration(milliseconds: 40),
          suiteName: 'soc',
        ),
      ],
    );
    final store = await SqlTrendStore.open(path: '${tmp.path}/trends.db');
    addTearDown(store.close);

    await const TrendStoreRebuilder().rebuild(
      store: store,
      archivePaths: [archive],
    );

    final alu = await store.queryAggregates(
      key: const TrendAggregateKey.perSuite('alu'),
      bucketSize: const Duration(days: 1),
    );
    expect(alu.single.totalRuns, 2);
    expect(alu.single.failCount, 1);
    final soc = await store.queryAggregates(
      key: const TrendAggregateKey.perSuite('soc'),
      bucketSize: const Duration(days: 1),
    );
    expect(soc.single.totalRuns, 1);
  });

  test('a replayed dump path is sweepable, not silently dropped', () async {
    // A rebuild that dropped `waveform_path` would exempt every restored
    // run's dump from `maxWaveformRuns` for good: the sweep finds dumps only
    // by reading that column back, and nothing else ever repopulates it.
    final started = DateTime.utc(2026, 6, 10, 12, 30, 15);
    final archive = await writeArchive(
      name: 'results.ndjson',
      runId: 'run-1',
      rows: [
        row(
          'alu/add',
          status: TestStatus.pass,
          startedAt: started,
          runtime: const Duration(milliseconds: 1250),
          waveformPath: '/work/run-1/alu_add/dump.fst',
        ),
        row(
          'alu/sub',
          status: TestStatus.fail,
          startedAt: started.add(const Duration(seconds: 2)),
          runtime: const Duration(milliseconds: 87),
        ),
      ],
    );
    final store = await SqlTrendStore.open(path: '${tmp.path}/trends.db');
    addTearDown(store.close);

    await const TrendStoreRebuilder().rebuild(
      store: store,
      archivePaths: [archive],
    );

    expect(
      await store.waveformPathsBeforeRecentRuns(0),
      ['/work/run-1/alu_add/dump.fst'],
    );
  });

  test('a recovered complete run is NOT relabelled interrupted', () async {
    // The failure this guards: `recordTrendPoints` creates the run row with a
    // null `finished_at`, and the next open marks every such row a crash. A
    // rebuild without the finish stamp would mark a user's entire recovered
    // history "interrupted".
    final archive = await writeArchive(
      name: 'complete.ndjson',
      runId: 'run-complete',
      rows: [
        row(
          't0',
          status: TestStatus.pass,
          startedAt: DateTime.utc(2026, 6, 10),
          runtime: const Duration(milliseconds: 5),
        ),
      ],
    );
    final dbPath = '${tmp.path}/trends.db';
    final store = await SqlTrendStore.open(path: dbPath);
    await const TrendStoreRebuilder().rebuild(
      store: store,
      archivePaths: [archive],
    );
    await store.close();

    // Next launch: reconciliation runs at open.
    final reopened = await SqlTrendStore.open(path: dbPath);
    addTearDown(reopened.close);
    expect(await reopened.isRunInterrupted('run-complete'), isFalse);
  });

  test(
    'a truncated archive recovers its prefix and stays interrupted',
    () async {
      final archive = await writeArchive(
        name: 'crashed.ndjson',
        runId: 'run-crashed',
        complete: false,
        rows: [
          row(
            't0',
            status: TestStatus.pass,
            startedAt: DateTime.utc(2026, 6, 10),
            runtime: const Duration(milliseconds: 5),
          ),
          row(
            't1',
            status: TestStatus.fail,
            startedAt: DateTime.utc(2026, 6, 10, 0, 1),
            runtime: const Duration(milliseconds: 9),
          ),
        ],
      );
      // Simulate the half-written final line a SIGKILL leaves behind.
      final raw = File(archive).readAsStringSync();
      File(archive).writeAsStringSync('$raw{"type":"result","id":"t2","sta');

      final dbPath = '${tmp.path}/trends.db';
      final store = await SqlTrendStore.open(path: dbPath);
      final report = await const TrendStoreRebuilder().rebuild(
        store: store,
        archivePaths: [archive],
      );

      expect(
        report.pointsRecovered,
        2,
        reason: 'the complete prefix comes back',
      );
      expect(report.archives.single.runWasComplete, isFalse);
      await store.close();

      final reopened = await SqlTrendStore.open(path: dbPath);
      addTearDown(reopened.close);
      expect(
        await reopened.isRunInterrupted('run-crashed'),
        isTrue,
        reason: 'a run that never finished must not be recovered as if it had',
      );
    },
  );

  test('the archive is never rewritten by a rebuild', () async {
    final archive = await writeArchive(
      name: 'readonly.ndjson',
      runId: 'run-1',
      complete: false,
      rows: [
        row(
          't0',
          status: TestStatus.pass,
          startedAt: DateTime.utc(2026, 6, 10),
          runtime: const Duration(milliseconds: 5),
        ),
      ],
    );
    File(archive).writeAsStringSync(
      '${File(archive).readAsStringSync()}{"partial',
    );
    final before = File(archive).readAsStringSync();

    final store = await SqlTrendStore.open(path: '${tmp.path}/trends.db');
    addTearDown(store.close);
    await const TrendStoreRebuilder().rebuild(
      store: store,
      archivePaths: [archive],
    );

    expect(
      File(archive).readAsStringSync(),
      before,
      reason:
          'recovery is read-only over the only surviving copy of a run; '
          'trimming it in place is the business of the export pipeline, '
          'not of a recovery path',
    );
  });

  test('rows whose toolchain never launched are not replayed', () async {
    final archive = await writeArchive(
      name: 'infra.ndjson',
      runId: 'run-1',
      rows: [
        row(
          'ok',
          status: TestStatus.pass,
          startedAt: DateTime.utc(2026, 6, 10),
          runtime: const Duration(milliseconds: 5),
        ),
        row(
          'no-simulator',
          status: TestStatus.fail,
          startedAt: DateTime.utc(2026, 6, 10),
          runtime: Duration.zero,
          didExecute: false,
        ),
      ],
    );
    final store = await SqlTrendStore.open(path: '${tmp.path}/trends.db');
    addTearDown(store.close);

    final report = await const TrendStoreRebuilder().rebuild(
      store: store,
      archivePaths: [archive],
    );

    expect(report.pointsRecovered, 1);
    expect(report.archives.single.rowsSkipped, 1);
    expect(
      (await store.pointsForRun('run-1')).map((p) => p.testId),
      ['ok'],
      reason:
          'a missing iverilog is not a fact about the test, and the live '
          'ingest path excludes it — the rebuild must match',
    );
  });

  test('replaying the same archive twice does not double-count', () async {
    final archive = await writeArchive(
      name: 'results.ndjson',
      runId: 'run-1',
      rows: [
        row(
          't0',
          status: TestStatus.pass,
          startedAt: DateTime.utc(2026, 6, 10),
          runtime: const Duration(milliseconds: 5),
        ),
      ],
    );
    final store = await SqlTrendStore.open(path: '${tmp.path}/trends.db');
    addTearDown(store.close);
    const rebuilder = TrendStoreRebuilder();

    await rebuilder.rebuild(store: store, archivePaths: [archive]);
    final second = await rebuilder.rebuild(
      store: store,
      archivePaths: [archive],
    );

    expect(
      second.archives.single.outcome,
      TrendStoreArchiveOutcome.alreadyPresent,
    );
    expect(second.pointsRecovered, 0);
    expect(await store.resultRowCount(), 1);
  });

  test('one unreadable archive does not abandon the others', () async {
    final good = await writeArchive(
      name: 'good.ndjson',
      runId: 'run-good',
      rows: [
        row(
          't0',
          status: TestStatus.pass,
          startedAt: DateTime.utc(2026, 6, 10),
          runtime: const Duration(milliseconds: 5),
        ),
      ],
    );
    final store = await SqlTrendStore.open(path: '${tmp.path}/trends.db');
    addTearDown(store.close);

    final report = await const TrendStoreRebuilder().rebuild(
      store: store,
      archivePaths: ['${tmp.path}/does-not-exist.ndjson', good],
    );

    expect(
      report.archives.first.outcome,
      TrendStoreArchiveOutcome.unreadable,
    );
    expect(report.archives.first.detail, isNotNull);
    expect(report.runsRecovered, 1);
    expect(report.pointsRecovered, 1);
    expect(report.archivesSkipped, 1);
  });

  test('an archive with no run id recovers nothing', () async {
    final archive = await writeArchive(
      name: 'headless.ndjson',
      runId: 'run-1',
      writeMeta: false,
      rows: [
        row(
          't0',
          status: TestStatus.pass,
          startedAt: DateTime.utc(2026, 6, 10),
          runtime: const Duration(milliseconds: 5),
        ),
      ],
    );
    final store = await SqlTrendStore.open(path: '${tmp.path}/trends.db');
    addTearDown(store.close);

    final report = await const TrendStoreRebuilder().rebuild(
      store: store,
      archivePaths: [archive],
    );

    expect(
      report.archives.single.outcome,
      TrendStoreArchiveOutcome.missingRunId,
      reason: 'inventing a run id would fabricate a run that never existed',
    );
    expect(await store.resultRowCount(), 0);
  });
}
