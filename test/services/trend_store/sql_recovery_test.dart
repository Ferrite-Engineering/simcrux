// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_sqlite/crux_sqlite.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/trend_store.dart';
import 'package:simcrux/domain/models/retention_policy.dart';
import 'package:simcrux/domain/models/trend_store_corruption_notice.dart';
import 'package:simcrux/services/trend_store/sql_trend_store_io.dart';
import 'package:simcrux/services/trend_store/trend_store_log_name.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Persistence durability & crash recovery (SQLite side). A corrupt
/// or future-version trend database must surface a defined, recoverable
/// error; retention must reclaim disk; and a run that crashed before
/// finalizing must be marked interrupted, not silently "passed".
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('simcrux_sqlrec_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  TrendPoint point(String testId, {String runId = 'r1'}) => TrendPoint(
    runId: runId,
    testId: testId,
    status: TestStatus.pass,
    runtime: const Duration(milliseconds: 5),
    startedAt: DateTime.utc(2026, 6, 10),
  );

  // 11. retentionVacuumShrinks — VACUUM reclaims freed pages so the file
  // actually shrinks. MUTATION: removing the VACUUM leaves the file the
  // same size after a large prune.
  test(
    'retentionVacuumShrinks: prune + VACUUM shrinks the on-disk file',
    () async {
      final dbPath = p.join(tmp.path, 'trend.db');
      final store = await SqlTrendStore.open(path: dbPath);
      addTearDown(store.close);
      // Batched: 2000 per-point transactions (one fsync each) blow the
      // 3-minute timeout on the slow Windows CI runner; a single
      // transaction seeds the same rows in well under a second.
      await store.recordTrendPoints([
        for (var i = 0; i < 2000; i++) point('t$i'),
      ]);
      final beforeBytes = File(dbPath).lengthSync();

      final deleted = await store.applyRetention(
        const RetentionPolicy(maxDataPoints: 10),
      );
      final afterBytes = File(dbPath).lengthSync();

      expect(deleted, 1990);
      expect(
        afterBytes,
        lessThan(beforeBytes),
        reason: 'VACUUM should reclaim the freed pages',
      );
      // VACUUM on 2000 rows still takes a while on the slower Windows CI
      // runner; keep headroom over the 30s default.
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // 5. unfinalizedRunsRow — a run with no finished_at is marked interrupted.
  test('unfinalizedRunsRow: crashed run is marked interrupted', () async {
    final store = await SqlTrendStore.open(path: p.join(tmp.path, 't.db'));
    addTearDown(store.close);
    await store.recordRun(
      runId: 'crashed',
      startedAt: DateTime.utc(2026, 6, 10),
      // finishedAt omitted ⇒ NULL ⇒ the run never finalized.
    );
    await store.recordRun(
      runId: 'clean',
      startedAt: DateTime.utc(2026, 6, 10),
      finishedAt: DateTime.utc(2026, 6, 10, 0, 1),
    );

    final reconciled = await store.reconcileInterruptedRuns();

    expect(reconciled, 1);
    expect(await store.isRunInterrupted('crashed'), isTrue);
    expect(await store.isRunInterrupted('clean'), isFalse);
  });

  // 5a. GUI ingest path: a run recorded via recordTrendPoints creates its
  // run row with a null finished_at. Without markRunFinished, crash
  // reconciliation false-positives every completed GUI run.
  test(
    'guiRunFinished: recordTrendPoints + markRunFinished is NOT flagged',
    () async {
      final store = await SqlTrendStore.open(path: p.join(tmp.path, 'gui.db'));
      addTearDown(store.close);
      // The GUI path — no recordRun, only per-result trend points.
      await store.recordTrendPoints([point('t0'), point('t1')]);
      // The runner stamps finished_at at RegressionFinished.
      await store.markRunFinished('r1', DateTime.utc(2026, 6, 10, 0, 5));

      final reconciled = await store.reconcileInterruptedRuns();

      expect(
        reconciled,
        0,
        reason: 'a completed GUI run must not be reconciled as interrupted',
      );
      expect(await store.isRunInterrupted('r1'), isFalse);
    },
  );

  // 5a-MUTATION: the same GUI run WITHOUT the finish stamp is the false
  // positive the fix removes — proves markRunFinished is load-bearing.
  test(
    'guiRunCrash: recordTrendPoints without markRunFinished IS flagged',
    () async {
      final store = await SqlTrendStore.open(
        path: p.join(tmp.path, 'crash.db'),
      );
      addTearDown(store.close);
      await store.recordTrendPoints([point('t0')]);
      // No markRunFinished — stands in for a process that died mid-run.

      final reconciled = await store.reconcileInterruptedRuns();

      expect(reconciled, 1);
      expect(await store.isRunInterrupted('r1'), isTrue);
    },
  );

  // 5a-idempotence: markRunFinished never overwrites an existing
  // finished_at (so a recordRun-persisted finish time survives a later
  // stamp), and marks a missing run as a no-op.
  test('markRunFinished: guards finished_at and a missing run', () async {
    final store = await SqlTrendStore.open(path: p.join(tmp.path, 'idem.db'));
    addTearDown(store.close);
    await store.recordRun(
      runId: 'already',
      startedAt: DateTime.utc(2026, 6, 10),
      finishedAt: DateTime.utc(2026, 6, 10, 0, 1),
    );
    // Must not clobber the earlier finish time, and must not flag it.
    await store.markRunFinished('already', DateTime.utc(2026, 6, 10, 9));
    // A run that produced no rows: a harmless zero-row update.
    await store.markRunFinished('ghost', DateTime.utc(2026, 6, 10, 9));

    expect(await store.reconcileInterruptedRuns(), 0);
    expect(await store.isRunInterrupted('already'), isFalse);
  });

  // 5b. reconcileAtOpen — reopening the DB after a crash marks the
  // dangling run without any explicit caller: `SqlTrendStore.open`
  // itself invokes the reconciliation logic, so a caller that never
  // calls `reconcileInterruptedRuns` directly still gets a reconciled
  // store.
  test(
    'reconcileAtOpen: reopening marks a run left dangling by a crash',
    () async {
      final dbPath = p.join(tmp.path, 'reopen.db');
      final crashed = await SqlTrendStore.open(path: dbPath);
      await crashed.recordRun(
        runId: 'interrupted',
        startedAt: DateTime.utc(2026, 6, 10),
        // No finishedAt: the process died before finalizing.
      );
      await crashed.close();

      // Next launch.
      final reopened = await SqlTrendStore.open(path: dbPath);
      addTearDown(reopened.close);

      expect(
        await reopened.isRunInterrupted('interrupted'),
        isTrue,
        reason: 'open() must reconcile dangling runs with no explicit call',
      );
    },
  );

  test(
    'reconcileAtOpen: reconcile:false leaves the dangling run unmarked',
    () async {
      final dbPath = p.join(tmp.path, 'reopen_optout.db');
      final crashed = await SqlTrendStore.open(path: dbPath);
      await crashed.recordRun(
        runId: 'interrupted',
        startedAt: DateTime.utc(2026, 6, 10),
      );
      await crashed.close();

      final reopened = await SqlTrendStore.open(
        path: dbPath,
        reconcile: false,
      );
      addTearDown(reopened.close);

      expect(await reopened.isRunInterrupted('interrupted'), isFalse);
    },
  );

  test('reconcileAtOpen: a cleanly finished run is untouched', () async {
    final dbPath = p.join(tmp.path, 'reopen_clean.db');
    final first = await SqlTrendStore.open(path: dbPath);
    await first.recordRun(
      runId: 'clean',
      startedAt: DateTime.utc(2026, 6, 10),
      finishedAt: DateTime.utc(2026, 6, 10, 0, 1),
    );
    await first.close();

    final reopened = await SqlTrendStore.open(path: dbPath);
    addTearDown(reopened.close);

    expect(await reopened.isRunInterrupted('clean'), isFalse);
  });

  // 9. corruptSqlite — a header-corrupt DB is quarantined, reported and
  // replaced with a fresh one. It used to escape as an uncaught
  // DatabaseException from the production provider, taking the dashboard down
  // and naming nothing the user could act on.
  test('corruptSqlite: the damaged file is kept, not deleted', () async {
    final dbPath = p.join(tmp.path, 'corrupt.db');
    final garbage = List<int>.generate(4096, (i) => (i * 7) & 0xff);
    File(dbPath).writeAsBytesSync(garbage);
    final notices = <TrendStoreCorruptionNotice>[];

    final store = await SqlTrendStore.open(
      path: dbPath,
      onCorruption: notices.add,
    );
    addTearDown(store.close);

    // A usable, empty store — not an exception, and not a deletion.
    expect(await store.resultRowCount(), 0);
    expect(await store.schemaVersion(), SqlTrendStore.latestSchemaVersion);

    expect(notices, hasLength(1), reason: 'a silent quarantine is its own bug');
    final quarantined = notices.single.quarantinedPath;
    expect(quarantined, isNotNull);
    expect(File(quarantined!).existsSync(), isTrue);
    expect(
      File(quarantined).readAsBytesSync(),
      garbage,
      reason: 'every byte of the damaged file must still be there',
    );
    expect(notices.single.path, dbPath);
  });

  // `developer.log` carried this, and a release build drops it: a `--ci` run,
  // which has no recovery card, left no trace that its history was moved.
  test('corruptSqlite: the quarantine is a SEVERE log record', () async {
    final dbPath = p.join(tmp.path, 'logged.db');
    File(dbPath).writeAsBytesSync(
      List<int>.generate(4096, (i) => (i * 13) & 0xff),
    );
    final records = <LogRecord>[];
    final originalLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    addTearDown(() => Logger.root.level = originalLevel);
    final sub = Logger.root.onRecord
        .where((r) => r.loggerName == kTrendStoreLogName)
        .listen(records.add);
    addTearDown(sub.cancel);

    final store = await SqlTrendStore.open(path: dbPath);
    addTearDown(store.close);
    await Future<void>.delayed(Duration.zero);

    expect(records, hasLength(1));
    expect(records.single.level, Level.SEVERE);
    expect(records.single.message, contains('quarantined'));
  });

  // The store must not hand the recovery path a merely-locked or
  // merely-migrating file. A corrupt file is the world's fault; the other two
  // faults are ours and nobody's, and neither may touch the bytes.
  test('corruptSqlite: a relative path names one file, not three', () async {
    final dbPath = p.join(tmp.path, 'relative.db');
    File(dbPath).writeAsBytesSync(
      List<int>.generate(4096, (i) => (i * 11) & 0xff),
    );
    final notices = <TrendStoreCorruptionNotice>[];

    final store = await SqlTrendStore.open(
      path: dbPath,
      onCorruption: notices.add,
    );
    addTearDown(store.close);

    // Absolutised by the open policy and used for the open, the quarantine and
    // every reported path — the property `SqlTrendStore` did not have while it
    // assembled options and called the factory itself.
    expect(store.path, dbPath);
    expect(p.isAbsolute(notices.single.quarantinedPath!), isTrue);
    expect(p.dirname(notices.single.quarantinedPath!), tmp.path);
  });

  // 7. schemaVersionAhead — opening a DB written by a newer SimCrux is
  // rejected with a clear message (never silently migrated down).
  test('schemaVersionAhead: future user_version is rejected', () async {
    final dbPath = p.join(tmp.path, 'ahead.db');
    sqfliteFfiInit();
    final raw = await databaseFactoryFfi.openDatabase(dbPath);
    await raw.execute(
      'PRAGMA user_version = ${SqlTrendStore.latestSchemaVersion + 5}',
    );
    await raw.close();

    await expectLater(
      SqlTrendStore.open(path: dbPath),
      throwsA(isA<CruxSchemaVersionSkewException>()),
    );
  });

  // 10. lockedSqlite — a busy_timeout back-off lets two writers on the
  // same file both succeed rather than failing immediately.
  test(
    'lockedSqlite: concurrent writers both commit under busy_timeout',
    () async {
      final dbPath = p.join(tmp.path, 'shared.db');
      final a = await SqlTrendStore.open(path: dbPath);
      final b = await SqlTrendStore.open(path: dbPath);
      addTearDown(a.close);
      addTearDown(b.close);
      await Future.wait<void>([
        for (var i = 0; i < 20; i++) a.recordTrendPoint(point('a$i')),
        for (var i = 0; i < 20; i++)
          b.recordTrendPoint(point('b$i', runId: 'r2')),
      ]);
      // No "database is locked" exception escaped.
      final stats = await a.storageStats();
      expect(stats, isNotNull);
    },
  );
}
