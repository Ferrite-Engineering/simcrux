// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';

import 'package:crux_sqlite/crux_sqlite.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:simcrux/core/app_info/build_info.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/trend_store.dart';
import 'package:simcrux/domain/models/retention_policy.dart';
import 'package:simcrux/domain/models/trend_aggregate.dart';
import 'package:simcrux/domain/models/trend_schema_info.dart';
import 'package:simcrux/domain/models/trend_storage_stats.dart';
import 'package:simcrux/domain/models/trend_store_corruption_notice.dart';
import 'package:simcrux/services/trend_store/sql_migrations.dart';
import 'package:simcrux/services/trend_store/trend_store_log_name.dart';
import 'package:sqflite_common/sqflite.dart';

/// `dart:io`-backed SQLite trend store.
///
/// Re-exported as the default [TrendStore] implementation on every
/// non-web platform via `sql_trend_store.dart`'s conditional export.
/// On web, the export switches to a no-op stub (web dashboards are
/// backed by the in-memory store only).
///
/// Scope:
///
/// - Open a SQLite database via `sqflite_common_ffi` at the path the
///   caller provides (`null` ⇒ in-memory).
/// - Apply versioned migrations (see [simcruxTrendStoreMigrations], run by
///   `package:crux_sqlite`'s `CruxMigrationRunner`).
/// - Reject downgrades.
/// - Record one trend point per terminal test result.
/// - Query recent trend points for a single test and recent status
///   deltas across the last N runs (the two surfaces used by the
///   trend mini-view).
class SqlTrendStore extends TrendStore {
  /// Private constructor — callers go through [open].
  SqlTrendStore._(this._db);

  /// Owns [simcruxTrendStoreMigrations] and is the only thing that runs
  /// them. Derives the latest schema version from the list, so there is no
  /// constant to forget to bump.
  static final CruxMigrationRunner _migrationRunner = CruxMigrationRunner(
    storeName: 'SimCrux trend store',
    migrations: simcruxTrendStoreMigrations,
    // Who is writing to the file, stamped into `schema_meta` and every
    // ledger row. `crux_sqlite` is pure Dart and deliberately cannot source
    // this itself — `PackageInfo.fromPlatform()` is Flutter-only and async,
    // and neither product's headless CLI has it. So the product supplies it,
    // from a constant a static guard keeps honest.
    identity: CruxAppIdentity(
      product: SimCruxBuildInfo.productName,
      appVersion: SimCruxBuildInfo.productVersion,
    ),
  );

  /// The schema version this build produces, derived from
  /// [simcruxTrendStoreMigrations].
  static int get latestSchemaVersion => _migrationRunner.latestVersion;

  /// What this store's contents are worth, as the type the open path takes.
  ///
  /// **One declaration, three consequences**, which is why it is a named
  /// constant rather than an inline argument: `renameAside` is PRECIOUS, so
  /// (a) the file is never deleted on corruption — the damaged bytes are
  /// renamed to `` `<db>.corrupt-<ISO 8601 basic UTC>` `` and kept, (b) every
  /// schema upgrade of it is preceded by a `VACUUM INTO` snapshot that must
  /// succeed for the upgrade to run, and (c) a downgrade refusal can name that
  /// snapshot (`crux-shared/packages/crux_sqlite/README.md`, rules 4 and 5).
  ///
  /// Changing this to `recreate` would remove all three protections in one
  /// edit and read as a simplification. `sql_pre_upgrade_backup_test.dart`
  /// pins it.
  @visibleForTesting
  static const CruxDbRecovery dataValue = CruxDbRecovery.renameAside;

  /// Whether [error] is an open fault that retrying cannot fix.
  ///
  /// Riverpod 3 retries a failed provider ten times with exponential backoff,
  /// and while it does the state is `AsyncLoading` *carrying* the error — so
  /// a `.when(loading:, error:)` consumer renders the spinner, not the error
  /// arm. Measured on a permanently failing open: 11 attempts over ~40
  /// seconds before the state finally became `AsyncError`. Forty seconds of a
  /// bare "…" and ~22 KB of log for a fault whose answer will not change.
  ///
  /// Corruption is deliberately NOT in this set. A corrupt file is recovered
  /// by the open policy — quarantined, reopened fresh — so that open
  /// succeeds and there is nothing to retry or report here.
  ///
  /// Declared on both halves of the conditional export so the web-safe
  /// provider can ask without naming `package:crux_sqlite`, which reaches
  /// `dart:io` through `sqflite_common_ffi`.
  static bool isPermanentOpenFault(Object error) =>
      error is CruxSchemaVersionSkewException ||
      error is CruxMigrationFailedException ||
      error is CruxBackupFailedException;

  /// Builds the open policy for one open, with [onCorruption] bound into its
  /// recovery listener.
  ///
  /// A policy per open rather than one static instance, because the listener
  /// is per-caller: the GUI routes it to the App Diagnostics recovery notice,
  /// a test collects it, a bare `open()` only logs. `CruxSqliteOpenPolicy`
  /// refuses to be constructed with a non-`refuse` recovery and no listener at
  /// all — a silent quarantine is not an expressible shape — so the log-only
  /// listener below is the floor, not a default anyone can forget.
  ///
  /// [onCorruption] takes the web-safe [TrendStoreCorruptionNotice] rather
  /// than the package's exception for the same reason [schemaInfo] returns a
  /// product model: this seam is declared identically by the web stub, and
  /// SimCrux's web tree must stay free of `package:crux_sqlite`. The mapping
  /// happens here, at the one boundary that has both types.
  static CruxSqliteOpenPolicy _policyFor(
    void Function(TrendStoreCorruptionNotice notice)? onCorruption,
  ) => CruxSqliteOpenPolicy(
    runner: _migrationRunner,
    recovery: dataValue,
    onRecovery: (notice) {
      // SEVERE through `package:logging`, not `developer.log`, which a
      // release build drops: the recovery card shows this in the GUI, but a
      // `--ci` run has no card, and its job log is only stderr.
      Logger(kTrendStoreLogName).severe(
        'Trend database quarantined: $notice',
        notice.cause,
        notice.stackTrace,
      );
      onCorruption?.call(
        TrendStoreCorruptionNotice(
          path: notice.path,
          quarantinedPath: notice.quarantinedPath,
          // The strictly better of the two offers when it exists, so it is
          // resolved here rather than left for the UI to go looking: a
          // pre-upgrade snapshot is a real database with real history, where
          // a rebuild can only reach the runs whose archives still exist.
          backupPath: CruxPreUpgradeBackup.latestBackupFor(notice.path),
          occurredAt: DateTime.now().toUtc(),
          causeDescription: '${notice.cause}',
        ),
      );
    },
  );

  /// The open policy this store actually uses, for tests that need to assert
  /// on the declaration rather than on its effects.
  ///
  /// `recovery` is not only the corruption policy: `CruxDbRecovery.isPrecious`
  /// is what switches the pre-upgrade `VACUUM INTO` backup on, so a test that
  /// pins this value is pinning both. Exposed rather than re-derived in the
  /// test, because a test that builds its own policy proves only that the test
  /// is precious.
  @visibleForTesting
  static CruxSqliteOpenPolicy get debugOpenPolicy => _policyFor(null);

  /// Opens (or creates) the trend database at [path]. Pass
  /// `inMemoryDatabasePath` (or null) to get an in-memory database —
  /// handy for tests and for a "blank slate" session.
  ///
  /// **This is the only open path**, and it goes through
  /// [CruxSqliteOpenPolicy.open] rather than assembling options and calling
  /// the factory itself. That buys two things the hand-rolled call did not
  /// have: [path] is absolutised once and then used for the open, the
  /// quarantine, the backup lookup and every reported path — so a relative
  /// path names one file rather than three — and genuine corruption is
  /// recovered per [dataValue] instead of escaping as a raw
  /// `DatabaseException` nobody could act on.
  ///
  /// Three faults, three outcomes:
  ///
  ///  * **Genuine corruption** — the bytes are not a SQLite database. The file
  ///    is renamed aside, a fresh database opens in its place, and
  ///    [onCorruption] is told. Nothing is deleted. The App Diagnostics
  ///    recovery card is what turns that notice into an offer to rebuild.
  ///  * **A migration failure** — our own bug. It propagates as a
  ///    `CruxMigrationFailedException`; sqflite ran it in an exclusive
  ///    transaction, so the file is untouched at its old version.
  ///  * **A version skew** — a `CruxSchemaVersionSkewException`. It
  ///    propagates. An older build refuses a newer file; it never wipes one to
  ///    make itself able to open it.
  ///
  /// `SQLITE_BUSY` is none of the three and triggers no recovery at all.
  ///
  /// Opening also reconciles runs a previous process left dangling —
  /// see [reconcileInterruptedRuns]. Pass `reconcile: false` to skip
  /// it (tests that assert on raw pre-reconciliation metadata).
  static Future<SqlTrendStore> open({
    String? path,
    bool reconcile = true,
    void Function(TrendStoreCorruptionNotice notice)? onCorruption,
  }) async {
    ensureCruxSqliteFfiInitialized();
    final dbPath = path ?? inMemoryDatabasePath;
    final db = await _policyFor(onCorruption).open(dbPath);
    final store = SqlTrendStore._(db);
    if (reconcile) {
      // A process that died mid-run (crash, SIGKILL, power loss) left
      // its `runs` row with `finished_at IS NULL`. Mark those
      // interrupted now, at the first moment a live process can see
      // them, so the dashboard never renders a dangling run as
      // silently complete. Best-effort: a reconciliation failure must
      // not make the store unopenable.
      try {
        await store.reconcileInterruptedRuns();
      } on Object {
        // Swallow: the store is usable without the marker.
      }
    }
    return store;
  }

  final Database _db;

  /// Absolute path of the backing database file, or the sqflite in-memory
  /// sentinel. Absolutised by the open policy, so this is the file that would
  /// be quarantined and the file a backup would sit next to — not whatever
  /// relative string the caller happened to pass.
  String get path => _db.path;

  /// Maximum `IN (…)` placeholders bound in one statement. SQLite's
  /// default `SQLITE_MAX_VARIABLE_NUMBER` is 999 on older builds;
  /// chunking well under it keeps the bulk queries portable across
  /// every bundled SQLite the suite ships with.
  static const int _kMaxInClauseArgs = 500;

  final StreamController<void> _dataChangedController =
      StreamController<void>.broadcast();

  int _queryCount = 0;

  /// Diagnostics / test hatch: the number of SQL statements this store
  /// has issued since [resetDebugQueryCount].
  ///
  /// Exists so the perf guards can assert an *algorithmic* property —
  /// "this call costs O(1) queries, not O(tests)" — instead of a
  /// wall-clock budget that goes flaky on a loaded CI runner. Not part
  /// of the [TrendStore] contract.
  int get debugQueryCount => _queryCount;

  /// Resets [debugQueryCount] to zero.
  void resetDebugQueryCount() => _queryCount = 0;

  /// Every read in this class funnels through here so [debugQueryCount]
  /// sees it.
  Future<List<Map<String, Object?>>> _rawQuery(
    String sql, [
    List<Object?>? args,
  ]) {
    _queryCount++;
    return _db.rawQuery(sql, args);
  }

  /// Closes the underlying database and the [dataChanged] stream.
  /// Call from your provider's dispose hook.
  Future<void> close() async {
    await _dataChangedController.close();
    await _db.close();
  }

  /// Whether the store is currently open. Useful for tests that
  /// re-open the same path to verify persistence.
  bool get isOpen => _db.isOpen;

  @override
  Stream<void> get dataChanged => _dataChangedController.stream;

  /// Notify listeners that the underlying database mutated. Safe to
  /// call after [close] (silently drops).
  void _notifyChanged() {
    if (_dataChangedController.isClosed) return;
    _dataChangedController.add(null);
  }

  @override
  Future<void> recordTrendPoint(TrendPoint point) async {
    // The trend store is the long-lived companion to
    // `ResultStore.recordResult`. Each recordTrendPoint call inserts
    // one row into `test_results`. The run row is created lazily so
    // a caller that buffers many results and inserts them
    // out-of-order across runs still gets correct grouping.
    await _db.transaction((txn) => _insertTrendPoint(txn, point));
    _notifyChanged();
  }

  /// The single-point insert body shared by [recordTrendPoint] and
  /// [recordTrendPoints]. Runs inside the caller's transaction.
  static Future<void> _insertTrendPoint(
    DatabaseExecutor txn,
    TrendPoint point,
  ) async {
    await txn.rawInsert(
      '''
INSERT OR IGNORE INTO runs (
  id, started_at, config_hash, trigger_kind, total_tests, metadata
) VALUES (?, ?, ?, ?, ?, ?)
''',
      <Object?>[
        point.runId,
        point.startedAt.toUtc().millisecondsSinceEpoch,
        '',
        // 'unknown', not 'manual'. A `TrendPoint` carries no trigger, so this
        // row cannot know one — and this is the path every run row actually
        // takes, `recordRun` having no production caller. Writing 'manual'
        // made a default look like evidence: the App Diagnostics rebuild
        // replays *CI* archives through here, and each replayed run came back
        // labelled a manual one, contradicting the recovery card's own
        // promise that the trigger cannot be recovered.
        'unknown',
        0,
        '{}',
      ],
    );
    await txn.rawInsert(
      '''
INSERT INTO test_results (
  id, run_id, test_name, suite_name, simulator, parameters,
  status, runtime_ms, started_at, waveform_path, metadata
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
''',
      <Object?>[
        '${point.runId}:${point.testId}',
        point.runId,
        point.testId,
        // Not decoration either: the per-suite trend view filters on this
        // column (`queryAggregates` with a per-suite key), so an unbound
        // suite leaves that view empty on every seat whose history lives in
        // this store. The column is NOT NULL; a point with no suite keeps
        // the empty string it always had.
        point.suiteName ?? '',
        '', // simulator not carried by TrendPoint
        '{}',
        point.status.name,
        point.runtime.inMilliseconds,
        point.startedAt.toUtc().millisecondsSinceEpoch,
        // Not decoration: `waveformPathsBeforeRecentRuns` — the whole of
        // `maxWaveformRuns` enforcement — reads this column back. Leaving it
        // unbound made the sweep's `WHERE waveform_path IS NOT NULL` match
        // nothing, so the policy reported itself honoured and swept no dumps.
        point.waveformPath,
        '{}',
      ],
    );
    // Increment the run-level total_tests count so the dashboard
    // can render run progress.
    await txn.rawUpdate(
      'UPDATE runs SET total_tests = total_tests + 1 WHERE id = ?',
      <Object?>[point.runId],
    );
  }

  /// Records many trend points in a single transaction — one commit
  /// (one fsync) and one [dataChanged] emission instead of one per
  /// point. Semantically identical to calling [recordTrendPoint] for
  /// each element; this is the production ingest path (the regression
  /// runner buffers per-result points and flushes them here), where
  /// per-point transactions are prohibitively slow on spinning/CI
  /// disks.
  @override
  Future<void> recordTrendPoints(Iterable<TrendPoint> points) async {
    if (points.isEmpty) return;
    await _db.transaction((txn) async {
      for (final point in points) {
        await _insertTrendPoint(txn, point);
      }
    });
    _notifyChanged();
  }

  /// Records a full run-level summary row in one shot. Useful for
  /// the CI / batch path where the in-memory store has the
  /// authoritative result list and the trend store is the persistence
  /// surface.
  ///
  /// Idempotent on `runId` — overwrites the existing row.
  Future<void> recordRun({
    required String runId,
    required DateTime startedAt,
    DateTime? finishedAt,
    String configHash = '',
    String triggerKind = 'manual',
    int totalTests = 0,
    int passed = 0,
    int failed = 0,
    int errored = 0,
    int timedOut = 0,
    int skipped = 0,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async {
    await _db.rawInsert(
      '''
INSERT OR REPLACE INTO runs (
  id, started_at, finished_at, config_hash, trigger_kind,
  total_tests, passed, failed, errored, timed_out, skipped, metadata
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
''',
      <Object?>[
        runId,
        startedAt.toUtc().millisecondsSinceEpoch,
        finishedAt?.toUtc().millisecondsSinceEpoch,
        configHash,
        triggerKind,
        totalTests,
        passed,
        failed,
        errored,
        timedOut,
        skipped,
        jsonEncode(metadata),
      ],
    );
    _notifyChanged();
  }

  @override
  Stream<TrendPoint> recentTrend(String testId, {int limit = 10}) async* {
    final rows = await _rawQuery(
      '''
SELECT run_id, test_name, status, runtime_ms, started_at
FROM test_results
WHERE test_name = ?
ORDER BY started_at DESC
LIMIT ?
''',
      <Object?>[testId, limit],
    );
    for (final row in rows) {
      yield TrendPoint(
        runId: row['run_id']! as String,
        testId: row['test_name']! as String,
        status: _statusFrom(row['status']! as String),
        runtime: Duration(milliseconds: row['runtime_ms']! as int),
        startedAt: DateTime.fromMillisecondsSinceEpoch(
          row['started_at']! as int,
          isUtc: true,
        ),
      );
    }
  }

  @override
  Future<List<TrendPoint>> pointsForRun(String runId) async {
    final rows = await _rawQuery(
      '''
SELECT run_id, test_name, status, runtime_ms, started_at
FROM test_results
WHERE run_id = ?
ORDER BY started_at ASC, test_name ASC
''',
      <Object?>[runId],
    );
    return [
      for (final row in rows)
        TrendPoint(
          runId: row['run_id']! as String,
          testId: row['test_name']! as String,
          status: _statusFrom(row['status']! as String),
          runtime: Duration(milliseconds: row['runtime_ms']! as int),
          startedAt: DateTime.fromMillisecondsSinceEpoch(
            row['started_at']! as int,
            isUtc: true,
          ),
        ),
    ];
  }

  /// Emits one [TrendDelta] per test whose status in the newest run
  /// differs from its newest status in the preceding `limit - 1` runs.
  ///
  /// **One query, not N+1.** A per-test `SELECT … LIMIT 1` round-trip
  /// to find each test's prior status does not scale: the dashboard's
  /// delta strip recomputes this on every trend flush tick mid-run
  /// (every 25 results / 250 ms), and a run of ~10k tests would mean
  /// ~10k round-trips through the single sqflite worker per call,
  /// starving the sparkline and flaky-panel queries queued behind it.
  /// Instead, the prior status is resolved for every test at once by a
  /// `ROW_NUMBER()` window over the run window, joined back to the
  /// newest run's rows.
  ///
  /// **[limit] bounds the comparison window**, per the interface
  /// contract: a prior result older than the newest `limit` runs reads
  /// as "no previous status" (`previousStatus == null`) rather than
  /// reaching arbitrarily far back into history.
  @override
  Stream<TrendDelta> recentDeltas({int limit = 10}) async* {
    if (limit <= 0) return;
    final rows = await _rawQuery(
      '''
WITH window_runs AS (
  SELECT id, started_at FROM runs ORDER BY started_at DESC LIMIT ?
),
newest AS (
  SELECT id FROM window_runs ORDER BY started_at DESC LIMIT 1
),
prior_ranked AS (
  SELECT
    r.test_name AS test_name,
    r.status    AS status,
    ROW_NUMBER() OVER (
      PARTITION BY r.test_name
      ORDER BY r.started_at DESC, r.run_id DESC
    ) AS rnk
  FROM test_results r
  JOIN window_runs w ON w.id = r.run_id
  WHERE r.run_id <> (SELECT id FROM newest)
)
SELECT
  c.run_id      AS current_run_id,
  c.test_name   AS test_name,
  c.status      AS current_status,
  p.status      AS previous_status
FROM test_results c
LEFT JOIN prior_ranked p
  ON p.test_name = c.test_name AND p.rnk = 1
WHERE c.run_id = (SELECT id FROM newest)
''',
      <Object?>[limit],
    );
    for (final row in rows) {
      final currentStatus = _statusFrom(row['current_status']! as String);
      final previousRaw = row['previous_status'] as String?;
      final previousStatus = previousRaw == null
          ? null
          : _statusFrom(previousRaw);
      if (previousStatus == currentStatus) continue;
      yield TrendDelta(
        testId: row['test_name']! as String,
        currentStatus: currentStatus,
        previousStatus: previousStatus,
        currentRunId: row['current_run_id']! as String,
      );
    }
  }

  /// Bulk [recentTrend]: one windowed query per chunk of [testIds]
  /// instead of one query per test.
  ///
  /// The Pro flaky-retry policy primes its score cache for every spec
  /// in a run before the first test is dispatched; at 10k specs the
  /// per-test form serialized 10k round-trips through the single
  /// sqflite worker into the run's critical path. `test_name IN (…)`
  /// is chunked at [_kMaxInClauseArgs] to stay clear of SQLite's bound
  /// -variable ceiling.
  @override
  Future<Map<String, List<TrendPoint>>> recentTrendsFor(
    Iterable<String> testIds, {
    int limit = 10,
  }) async {
    final ids = testIds.toSet().toList();
    final out = <String, List<TrendPoint>>{};
    if (ids.isEmpty || limit <= 0) return out;
    for (var start = 0; start < ids.length; start += _kMaxInClauseArgs) {
      final end = start + _kMaxInClauseArgs;
      final chunk = ids.sublist(start, end > ids.length ? ids.length : end);
      final placeholders = List<String>.filled(chunk.length, '?').join(', ');
      final rows = await _rawQuery(
        '''
SELECT run_id, test_name, status, runtime_ms, started_at FROM (
  SELECT
    run_id, test_name, status, runtime_ms, started_at,
    ROW_NUMBER() OVER (
      PARTITION BY test_name
      ORDER BY started_at DESC, run_id DESC
    ) AS rnk
  FROM test_results
  WHERE test_name IN ($placeholders)
)
WHERE rnk <= ?
ORDER BY test_name ASC, started_at DESC
''',
        <Object?>[...chunk, limit],
      );
      for (final row in rows) {
        final testName = row['test_name']! as String;
        (out[testName] ??= <TrendPoint>[]).add(
          TrendPoint(
            runId: row['run_id']! as String,
            testId: testName,
            status: _statusFrom(row['status']! as String),
            runtime: Duration(milliseconds: row['runtime_ms']! as int),
            startedAt: DateTime.fromMillisecondsSinceEpoch(
              row['started_at']! as int,
              isUtc: true,
            ),
          ),
        );
      }
    }
    return out;
  }

  /// Every distinct test id appearing in the newest [runWindow] runs.
  ///
  /// The honest enumerator for cross-test views: unlike [recentDeltas]
  /// it lists a test regardless of whether its status changed, so a
  /// test flapping inside the window but stable across the last two
  /// runs is still enumerated.
  @override
  Future<List<String>> distinctTestIds({int runWindow = 10}) async {
    if (runWindow <= 0) return const <String>[];
    final rows = await _rawQuery(
      '''
SELECT DISTINCT r.test_name AS test_name
FROM test_results r
JOIN (
  SELECT id FROM runs ORDER BY started_at DESC LIMIT ?
) w ON w.id = r.run_id
ORDER BY r.test_name ASC
''',
      <Object?>[runWindow],
    );
    return <String>[for (final row in rows) row['test_name']! as String];
  }

  @override
  Future<List<TrendPoint>> queryDataPoints({
    String? testId,
    String? suiteId,
    DateTime? since,
    int? limit,
    int? offset,
  }) async {
    final where = StringBuffer();
    final args = <Object?>[];
    void addClause(String clause, [Object? arg]) {
      if (where.isNotEmpty) where.write(' AND ');
      where.write(clause);
      if (arg != null) args.add(arg);
    }

    if (testId != null) addClause('test_name = ?', testId);
    if (suiteId != null && suiteId.isNotEmpty) {
      addClause('suite_name = ?', suiteId);
    }
    if (since != null) {
      addClause(
        'started_at >= ?',
        since.toUtc().millisecondsSinceEpoch,
      );
    }
    final whereClause = where.isEmpty ? '' : 'WHERE $where';
    final limitClause = limit != null ? 'LIMIT ?' : '';
    if (limit != null) args.add(limit);
    final offsetClause = offset != null ? 'OFFSET ?' : '';
    if (offset != null) args.add(offset);

    final rows = await _rawQuery(
      '''
SELECT run_id, test_name, status, runtime_ms, started_at
FROM test_results
$whereClause
ORDER BY started_at DESC
$limitClause
$offsetClause
''',
      args,
    );
    return [
      for (final row in rows)
        TrendPoint(
          runId: row['run_id']! as String,
          testId: row['test_name']! as String,
          status: _statusFrom(row['status']! as String),
          runtime: Duration(milliseconds: row['runtime_ms']! as int),
          startedAt: DateTime.fromMillisecondsSinceEpoch(
            row['started_at']! as int,
            isUtc: true,
          ),
        ),
    ];
  }

  @override
  Future<List<TrendAggregate>> queryAggregates({
    required TrendAggregateKey key,
    required Duration bucketSize,
    DateTime? since,
  }) async {
    if (bucketSize.inMilliseconds <= 0) {
      throw ArgumentError.value(
        bucketSize,
        'bucketSize',
        'bucketSize must be a positive duration',
      );
    }
    // Pull the matching rows and bucket in Dart. Doing the bucket
    // computation in Dart keeps the SQL portable and lets the
    // percentile computation use the canonical `computeRuntimePercentiles`
    // helper. For the row counts we expect under the default
    // retention policy (≤ 50k rows) this is well under one frame
    // budget on every supported platform.
    final whereParts = <String>[];
    final args = <Object?>[];
    switch (key.kind) {
      case TrendAggregateKeyKind.perTest:
        if (key.id != null) {
          whereParts.add('test_name = ?');
          args.add(key.id);
        }
      case TrendAggregateKeyKind.perSuite:
        if (key.id != null) {
          whereParts.add('suite_name = ?');
          args.add(key.id);
        }
      case TrendAggregateKeyKind.global:
    }
    if (since != null) {
      whereParts.add('started_at >= ?');
      args.add(since.toUtc().millisecondsSinceEpoch);
    }
    final whereClause = whereParts.isEmpty
        ? ''
        : 'WHERE ${whereParts.join(' AND ')}';
    final rows = await _rawQuery(
      '''
SELECT status, runtime_ms, started_at
FROM test_results
$whereClause
ORDER BY started_at ASC
''',
      args,
    );
    if (rows.isEmpty) return const <TrendAggregate>[];

    final bucketMs = bucketSize.inMilliseconds;
    final originMs = since != null
        ? since.toUtc().millisecondsSinceEpoch
        : rows.first['started_at']! as int;

    // Group by bucket index.
    final byBucket = <int, List<Map<String, Object?>>>{};
    for (final row in rows) {
      final t = row['started_at']! as int;
      final bucketIdx = (t - originMs) ~/ bucketMs;
      byBucket.putIfAbsent(bucketIdx, () => []).add(row);
    }

    final out = <TrendAggregate>[];
    final sortedKeys = byBucket.keys.toList()..sort();
    for (final idx in sortedKeys) {
      final bucketRows = byBucket[idx]!;
      final startMs = originMs + idx * bucketMs;
      var pass = 0;
      var fail = 0;
      var skip = 0;
      final runtimes = <int>[];
      for (final row in bucketRows) {
        final status = _statusFrom(row['status']! as String);
        final runtime = row['runtime_ms']! as int;
        runtimes.add(runtime);
        if (status == TestStatus.pass ||
            status == TestStatus.vacuous ||
            status == TestStatus.cover) {
          pass++;
        } else if (status == TestStatus.skipped ||
            status == TestStatus.cancelled) {
          skip++;
        } else {
          fail++;
        }
      }
      final percentiles = computeRuntimePercentiles(runtimes);
      out.add(
        TrendAggregate(
          key: key,
          windowStart: DateTime.fromMillisecondsSinceEpoch(
            startMs,
            isUtc: true,
          ),
          windowEnd: DateTime.fromMillisecondsSinceEpoch(
            startMs + bucketMs,
            isUtc: true,
          ),
          totalRuns: bucketRows.length,
          passCount: pass,
          failCount: fail,
          skipCount: skip,
          p50RuntimeMs: percentiles.p50,
          p95RuntimeMs: percentiles.p95,
          p99RuntimeMs: percentiles.p99,
        ),
      );
    }
    return out;
  }

  @override
  Future<int> applyRetention(RetentionPolicy policy) async {
    if (policy.isUnlimited) return 0;
    var deleted = 0;

    if (policy.maxAgeDays != null) {
      final cutoff = DateTime.now()
          .toUtc()
          .subtract(Duration(days: policy.maxAgeDays!))
          .millisecondsSinceEpoch;
      final n = await _db.rawDelete(
        'DELETE FROM test_results WHERE started_at < ?',
        <Object?>[cutoff],
      );
      deleted += n;
    }

    final maxPoints = policy.maxDataPoints;
    if (maxPoints != null) {
      final totalRows = await _rawQuery(
        'SELECT COUNT(*) AS c FROM test_results',
      );
      final current = totalRows.first['c']! as int;
      if (current > maxPoints) {
        final excess = current - maxPoints;
        switch (policy.pruneStrategy) {
          case RetentionPruneStrategy.oldestFirst:
            final n = await _db.rawDelete(
              '''
DELETE FROM test_results WHERE id IN (
  SELECT id FROM test_results ORDER BY started_at ASC LIMIT ?
)
''',
              <Object?>[excess],
            );
            deleted += n;
          case RetentionPruneStrategy.lowestValueFirst:
            // Time-bucket sampling: divide history into N buckets
            // (N == maxPoints / averageBucketSize). Retain the most
            // recent row in each bucket plus every row from the
            // newest 25% of buckets. The rest is eligible for
            // deletion.
            //
            // The exact ratio is tuned so freshness gets preference
            // (the user clicks "this week" most often) while still
            // preserving year-old samples.
            //
            // Implementation: rank rows by reverse-time; delete rows
            // whose rank falls into the "decimated" range.
            final ranked = await _rawQuery(
              '''
SELECT id, started_at,
  ROW_NUMBER() OVER (ORDER BY started_at DESC) AS rnk
FROM test_results
''',
            );
            final toDelete = <String>[];
            final freshCutoff = (maxPoints * 0.75).floor();
            for (final row in ranked) {
              final rnk = row['rnk']! as int;
              if (rnk <= freshCutoff) continue; // retain the freshest 75%
              // For the older slice, retain every K-th row where K
              // is chosen to land in maxPoints total. We have
              // (current - freshCutoff) rows in this slice and want
              // to retain (maxPoints - freshCutoff). Drop everything
              // not on the keep cadence.
              final olderCount = current - freshCutoff;
              final keepCount = maxPoints - freshCutoff;
              if (keepCount <= 0) {
                toDelete.add(row['id']! as String);
                continue;
              }
              final cadence = (olderCount / keepCount).ceil();
              final positionInSlice = rnk - freshCutoff - 1;
              if (positionInSlice % cadence != 0) {
                toDelete.add(row['id']! as String);
              }
            }
            // Batched, transactional delete. Row-at-a-time deletes in
            // autocommit cost one fsync each — a 50k-row decimation was
            // 50k commits, minutes of disk work on the post-run
            // retention pass. One transaction, chunked `IN (…)`
            // statements: one commit.
            deleted += await _deleteResultsByIdBatched(toDelete);
        }
      }
    }

    // Prune the `runs` table too. It was never pruned, so it grew
    // monotonically forever, and every `recentDeltas` call pays for it
    // in the `ORDER BY started_at` over runs (as does `storageStats`).
    //
    // Only rows that (a) have no surviving `test_results` and (b) began
    // strictly before the oldest surviving data point are removed. That
    // second guard is what keeps an in-flight run — whose `runs` row is
    // inserted before its first result lands — from being deleted out
    // from under the writer.
    //
    // Not added to `deleted`: the return value is documented as the
    // number of *data points* removed, and callers surface it as such.
    if (deleted > 0) {
      await _pruneOrphanedRuns();
    }

    if (deleted > 0) {
      // Retention is not just a logical delete: without VACUUM the file
      // keeps the freed pages and grows monotonically across months of
      // nightly runs. But VACUUM rewrites the entire database, so
      // running it after every post-run retention pass — which is what
      // happened once the DB was old enough for the age cutoff to bite
      // on every pass — turned a cheap prune into a full-file rewrite
      // each night. Only reclaim when there is enough dead space to be
      // worth the rewrite.
      if (await _shouldVacuum()) {
        await _db.execute('VACUUM');
      }
      _notifyChanged();
    }
    return deleted;
  }

  @override
  Future<List<String>> waveformPathsBeforeRecentRuns(int keepRuns) async {
    if (keepRuns < 0) return const <String>[];
    // Runs are ranked by their results' own timestamps rather than by
    // `runs.started_at`: a crash between the result flush and the run-row
    // write leaves orphaned results, and ranking off the runs table would
    // make those invisible to the sweep — the exact rows most likely to be
    // holding a large dump nobody is going to open.
    final rows = await _rawQuery(
      '''
SELECT DISTINCT waveform_path FROM test_results
WHERE waveform_path IS NOT NULL
  AND waveform_path <> ''
  AND run_id NOT IN (
    SELECT run_id FROM test_results
    GROUP BY run_id
    ORDER BY MAX(started_at) DESC
    LIMIT ?
  )
''',
      <Object?>[keepRuns],
    );
    return <String>[
      for (final row in rows)
        if (row['waveform_path'] case final String path) path,
    ];
  }

  @override
  Future<void> forgetWaveformPaths(Iterable<String> paths) async {
    final list = paths.toList(growable: false);
    if (list.isEmpty) return;
    await _db.transaction((txn) async {
      for (var start = 0; start < list.length; start += _kMaxInClauseArgs) {
        final end = start + _kMaxInClauseArgs;
        final chunk = list.sublist(
          start,
          end > list.length ? list.length : end,
        );
        final placeholders = List<String>.filled(chunk.length, '?').join(',');
        await txn.rawUpdate(
          'UPDATE test_results SET waveform_path = NULL '
          'WHERE waveform_path IN ($placeholders)',
          chunk,
        );
      }
    });
    _notifyChanged();
  }

  /// Deletes [ids] from `test_results` inside a single transaction,
  /// chunked into `IN (…)` statements of at most [_kMaxInClauseArgs].
  /// Returns the number of rows actually deleted.
  Future<int> _deleteResultsByIdBatched(List<String> ids) async {
    if (ids.isEmpty) return 0;
    var deleted = 0;
    await _db.transaction((txn) async {
      for (var start = 0; start < ids.length; start += _kMaxInClauseArgs) {
        final end = start + _kMaxInClauseArgs;
        final chunk = ids.sublist(start, end > ids.length ? ids.length : end);
        final placeholders = List<String>.filled(chunk.length, '?').join(', ');
        deleted += await txn.rawDelete(
          'DELETE FROM test_results WHERE id IN ($placeholders)',
          chunk,
        );
      }
    });
    return deleted;
  }

  /// Deletes `runs` rows that retain no `test_results` and started
  /// before the oldest surviving data point. Returns the row count.
  ///
  /// When no data points survive at all there is no safe cutoff (every
  /// run, including one currently being written, would qualify), so the
  /// prune is skipped rather than risking the live run's row.
  Future<int> _pruneOrphanedRuns() async {
    final boundsRows = await _rawQuery(
      'SELECT MIN(started_at) AS lo FROM test_results',
    );
    final lo = boundsRows.first['lo'];
    if (lo is! int) return 0;
    return _db.rawDelete(
      '''
DELETE FROM runs
WHERE started_at < ?
  AND id NOT IN (SELECT DISTINCT run_id FROM test_results)
''',
      <Object?>[lo],
    );
  }

  /// Minimum reclaimable bytes before a post-retention `VACUUM` is
  /// worth its full-file rewrite.
  static const int kVacuumMinReclaimableBytes = 8 * 1024 * 1024;

  /// Alternative VACUUM trigger: reclaim when this fraction of the file
  /// is dead pages, however small the file is in absolute terms. Keeps
  /// a small-but-mostly-empty database from staying bloated forever.
  static const double kVacuumMinFreeFraction = 0.25;

  /// Whether the freed-page count justifies a `VACUUM`. Reads
  /// `freelist_count` / `page_count` / `page_size`; any unexpected
  /// PRAGMA shape falls back to "don't vacuum" — a slightly larger file
  /// is strictly better than an unconditional full rewrite.
  Future<bool> _shouldVacuum() async {
    final freeRows = await _rawQuery('PRAGMA freelist_count');
    final pageRows = await _rawQuery('PRAGMA page_count');
    final sizeRows = await _rawQuery('PRAGMA page_size');
    final free = freeRows.isEmpty ? null : freeRows.first.values.first;
    final pages = pageRows.isEmpty ? null : pageRows.first.values.first;
    final pageSize = sizeRows.isEmpty ? null : sizeRows.first.values.first;
    if (free is! int || pages is! int || pageSize is! int) return false;
    if (free <= 0) return false;
    if (free * pageSize >= kVacuumMinReclaimableBytes) return true;
    if (pages <= 0) return false;
    return free / pages >= kVacuumMinFreeFraction;
  }

  /// Stamps [runId]'s `finished_at` so a run that completed normally is
  /// not later mistaken for a crash by [reconcileInterruptedRuns].
  ///
  /// The GUI path creates run rows via `INSERT OR IGNORE` in
  /// [_insertTrendPoint], which carries no finish time, so without this
  /// update every completed GUI run keeps a null `finished_at` and would
  /// be flagged interrupted at the next open. Scoped to `finished_at IS
  /// NULL` so a re-recorded run (e.g. `recordRun`) already carrying a
  /// finish time is not overwritten. A missing run row (a run with no
  /// recorded results) updates zero rows — a harmless no-op.
  @override
  Future<void> markRunFinished(String runId, DateTime finishedAt) async {
    await _db.rawUpdate(
      'UPDATE runs SET finished_at = ? WHERE id = ? AND finished_at IS NULL',
      <Object?>[finishedAt.toUtc().millisecondsSinceEpoch, runId],
    );
  }

  /// Marks every run that crashed before finalizing (`finished_at IS NULL`)
  /// as `interrupted` in its metadata. Returns the number reconciled.
  ///
  /// A normally-completed run is stamped by [markRunFinished] at
  /// [RegressionFinished], so only runs whose process died before that
  /// call still have a null `finished_at` — those are the genuine
  /// crashes this reconciles. The `interrupted` marker it writes is
  /// readable via [isRunInterrupted].
  ///
  /// The reconciliation counterpart to ndjson recovery: after a crash the
  /// ndjson tail is trimmed and the orphaned `runs` row is marked here.
  Future<int> reconcileInterruptedRuns() async {
    final rows = await _rawQuery(
      'SELECT id, metadata FROM runs WHERE finished_at IS NULL',
    );
    for (final row in rows) {
      final raw = row['metadata'] as String? ?? '{}';
      final decoded = jsonDecode(raw);
      final meta = decoded is Map<String, Object?>
          ? Map<String, Object?>.of(decoded)
          : <String, Object?>{};
      meta['interrupted'] = true;
      await _db.rawUpdate(
        'UPDATE runs SET metadata = ? WHERE id = ?',
        <Object?>[jsonEncode(meta), row['id']],
      );
    }
    if (rows.isNotEmpty) _notifyChanged();
    return rows.length;
  }

  /// Diagnostics / test hatch: runs a raw read query (e.g.
  /// `EXPLAIN QUERY PLAN …`, `PRAGMA …`, a `sqlite_master` lookup) against
  /// the underlying database. Not part of the [TrendStore] contract;
  /// exposed so perf benches can assert the query planner uses the right
  /// index and the schema carries the expected objects.
  Future<List<Map<String, Object?>>> debugRawQuery(
    String sql, [
    List<Object?> args = const <Object?>[],
  ]) => _db.rawQuery(sql, args);

  /// Whether [runId]'s metadata carries the `interrupted` marker set by
  /// [reconcileInterruptedRuns].
  Future<bool> isRunInterrupted(String runId) async {
    final rows = await _rawQuery(
      'SELECT metadata FROM runs WHERE id = ?',
      <Object?>[runId],
    );
    if (rows.isEmpty) return false;
    final decoded = jsonDecode(rows.first['metadata'] as String? ?? '{}');
    return decoded is Map && decoded['interrupted'] == true;
  }

  /// What the file says about itself: its `schema_meta` row and the tail of
  /// its `schema_migrations` ledger.
  ///
  /// Returns [CruxSchemaHistory.absent] for a `trends.db` written before v4 —
  /// which every existing install is, until the first launch that migrates it.
  /// Absence is a state to render, not an error: a store that treated it as a
  /// failure would be broken for exactly the population the ledger was added
  /// to help.
  ///
  /// [ledgerLimit] rows, newest version first. The App Diagnostics dialog
  /// shows the last few; pass a negative value for the whole ledger.
  Future<CruxSchemaHistory> schemaHistory({int ledgerLimit = 5}) =>
      readCruxSchemaHistory(_db, ledgerLimit: ledgerLimit);

  /// [schemaHistory] mapped into the presentation model the UI renders.
  ///
  /// The mapping lives here, in the io-only half of the conditional export,
  /// because `package:crux_sqlite` reaches `dart:io` through
  /// `sqflite_common_ffi` and SimCrux ships a web build. The web stub answers
  /// [TrendSchemaInfo.absent], which is also the honest answer there.
  @override
  Future<TrendSchemaInfo> schemaInfo({int ledgerLimit = 5}) async {
    final history = await schemaHistory(ledgerLimit: ledgerLimit);
    final meta = history.meta;
    if (meta == null) return TrendSchemaInfo.absent;
    return TrendSchemaInfo(
      schemaVersion: meta.schemaVersion,
      migratedByAppVersion: meta.appVersion,
      lastMigratedAt: meta.lastMigratedAt,
      lastOpenedByAppVersion: meta.lastOpenedByAppVersion,
      ledger: <TrendSchemaLedgerEntry>[
        for (final row in history.ledger)
          TrendSchemaLedgerEntry(
            version: row.version,
            description: row.description,
            appliedAt: row.appliedAt,
            appliedByAppVersion: row.appliedByAppVersion,
          ),
      ],
    );
  }

  @override
  Future<TrendStorageStats> storageStats() async {
    final countRows = await _rawQuery(
      'SELECT COUNT(*) AS c FROM test_results',
    );
    final dataCount = countRows.first['c']! as int;
    final runRows = await _rawQuery('SELECT COUNT(*) AS c FROM runs');
    final runCount = runRows.first['c']! as int;
    DateTime? oldest;
    DateTime? newest;
    if (dataCount > 0) {
      final boundsRows = await _rawQuery(
        'SELECT MIN(started_at) AS lo, MAX(started_at) AS hi FROM test_results',
      );
      final lo = boundsRows.first['lo'];
      final hi = boundsRows.first['hi'];
      if (lo is int) {
        oldest = DateTime.fromMillisecondsSinceEpoch(lo, isUtc: true);
      }
      if (hi is int) {
        newest = DateTime.fromMillisecondsSinceEpoch(hi, isUtc: true);
      }
    }
    // sqflite doesn't surface page-count directly via a typed API on
    // every platform — leave the byte estimate null and let the UI
    // display "unknown" rather than risk a misleading number.
    return TrendStorageStats(
      dataPointCount: dataCount,
      runCount: runCount,
      oldestPointAt: oldest,
      newestPointAt: newest,
    );
  }

  /// Returns the number of rows currently in `test_results`. Used by
  /// tests and the diagnostics report.
  Future<int> resultRowCount() async {
    final rows = await _rawQuery('SELECT COUNT(*) AS c FROM test_results');
    return rows.first['c']! as int;
  }

  /// Returns the number of runs currently in `runs`. Used by tests
  /// and the diagnostics report.
  Future<int> runRowCount() async {
    final rows = await _rawQuery('SELECT COUNT(*) AS c FROM runs');
    return rows.first['c']! as int;
  }

  /// Returns the current SQLite `user_version` (matches the value
  /// `databaseFactory.openDatabase` wrote on creation / upgrade).
  /// Used by tests to assert the migrations ran.
  Future<int> schemaVersion() async {
    final rows = await _rawQuery('PRAGMA user_version');
    return rows.first.values.first! as int;
  }

  static TestStatus _statusFrom(String name) {
    for (final s in TestStatus.values) {
      if (s.name == name) return s;
    }
    return TestStatus.unknown;
  }
}
