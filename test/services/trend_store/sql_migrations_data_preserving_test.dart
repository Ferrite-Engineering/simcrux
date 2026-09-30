// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_sqlite/crux_sqlite.dart';
import 'package:crux_sqlite/crux_sqlite_test_support.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/services/trend_store/sql_trend_store_io.dart';

/// The property `sql_migrations_test.dart` never checks: that data
/// survives an upgrade. That file opens empty in-memory databases and
/// asserts `sqlite_master` names only; this one builds a populated fixture
/// at every historical schema version, upgrades it to HEAD through the real
/// production open path, and checks row counts, per-column values, index
/// presence, and the round trip through [SqlTrendStore] itself.
///
/// Historical note for the record: once real user data exists post-1.0, an
/// anonymised real-world `trends.db` fixture per version is worth adding
/// alongside these synthetic ones — a freshly built file has no page-level
/// history the way a file that lived through months of real retention
/// passes does, and that history is exactly what a subtle migration bug
/// would corrupt.
///
/// `runs` and `test_results` (plus their indexes) have not changed shape
/// since v1 — versions 2 and 3 only add indexes, and v4 only adds the
/// `schema_meta` / `schema_migrations` tables — so one seed/assert shape
/// covers every version; what differs per version is which indexes and
/// ledger rows must already/not-yet exist.
Map<String, Object?> _runRow(String id, int startedAt) => <String, Object?>{
  'id': id,
  'started_at': startedAt,
  'finished_at': startedAt + 60000,
  'config_hash': 'cfg-$id',
  'git_commit': 'deadbeef',
  'git_branch': 'main',
  'trigger_kind': 'manual',
  'total_tests': 1,
  'passed': 1,
  'failed': 0,
  'errored': 0,
  'timed_out': 0,
  'skipped': 0,
  'metadata': '{"note":"m7-fixture"}',
};

Map<String, Object?> _resultRow(String id, String runId, int startedAt) =>
    <String, Object?>{
      'id': id,
      'run_id': runId,
      'test_name': 'tb_alu_add',
      'suite_name': 'core',
      'simulator': 'verilator',
      'parameters': '{"seed":7}',
      'status': 'pass',
      'runtime_ms': 4321,
      'started_at': startedAt,
      'log_path': '/logs/$id.log',
      'waveform_path': '/waves/$id.fst',
      'failure_reason': null,
      'metadata': '{"lane":2}',
    };

/// The full set of indexes the HEAD schema declares, regardless of which
/// historical version the fixture started from — every fixture must reach
/// this set after upgrading, which is the point of the assertion.
const Set<String> _headTestResultsIndexes = {
  'idx_results_run',
  'idx_results_test_name',
  'idx_results_status',
  'idx_results_simulator',
  'idx_results_test_started',
};
const Set<String> _headRunsIndexes = {'idx_runs_started'};

CruxMigrationFixture _fixture(int version) {
  final runId = 'run-v$version';
  final resultId = 'result-v$version';
  final startedAt = DateTime.utc(2026, 6).millisecondsSinceEpoch;

  return CruxMigrationFixture(
    seed: (db, seedVersion) async {
      expect(seedVersion, version);
      await db.insert('runs', _runRow(runId, startedAt));
      await db.insert(
        'test_results',
        _resultRow(resultId, runId, startedAt),
      );
    },
    assertAfterUpgrade: (migrated, seedVersion, dbPath) async {
      expect(seedVersion, version);

      // Counts unchanged.
      final runs = await migrated.query('runs');
      final results = await migrated.query('test_results');
      expect(runs, hasLength(1), reason: 'no run row must appear or vanish');
      expect(
        results,
        hasLength(1),
        reason: 'no test_results row must appear or vanish',
      );

      // Every pre-existing column, field by field — not just counted.
      expect(runs.single, equals(_runRow(runId, startedAt)));
      expect(results.single, equals(_resultRow(resultId, runId, startedAt)));

      // Every index the head schema declares, whichever version this
      // fixture started from.
      expect(
        await cruxIndexNamesOf(migrated, table: 'test_results'),
        containsAll(_headTestResultsIndexes),
      );
      expect(
        await cruxIndexNamesOf(migrated, table: 'runs'),
        containsAll(_headRunsIndexes),
      );

      // The ledger backfill: versions at or below the
      // fixture's starting version predate the ledger and are recorded with
      // NULL applied_at/applied_by_app_version; versions above it were
      // watched by this upgrade and carry both.
      //
      // The v(latestVersion) fixture is the one exception, and asserting it
      // separately is the point of this whole check (a case a copy-pasted,
      // hard-coded "N-1 to head" test would never exercise): building it is
      // a single onCreate(0, latestVersion) pass, so schema_meta is created
      // AND fully populated in that one pass with oldVersion == 0 throughout
      // — there is no "old file" for anything to predate, so every entry
      // gets a real timestamp and none are backfilled. Reopening it at HEAD
      // afterwards is a no-op (already current) that changes nothing.
      final history = await readCruxSchemaHistory(migrated, ledgerLimit: -1);
      expect(history.isPresent, isTrue);
      expect(history.meta!.schemaVersion, SqlTrendStore.latestSchemaVersion);
      final noUpgradeRan = version == SqlTrendStore.latestSchemaVersion;
      for (final entry in history.ledger) {
        if (!noUpgradeRan && entry.version <= version) {
          expect(
            entry.isBackfilled,
            isTrue,
            reason:
                "v${entry.version} predates this fixture's starting point "
                '(v$version) and must be recorded as backfilled, not '
                'invented',
          );
        } else {
          expect(
            entry.isBackfilled,
            isFalse,
            reason: noUpgradeRan
                ? 'v${entry.version} was written by the single onCreate(0, '
                      '4) pass that built this fixture, with no "old file" '
                      'to predate — it must carry a real timestamp'
                : 'v${entry.version} ran DURING this very upgrade and '
                      'must be recorded as such',
          );
        }
      }

      // The round trip: the data reads back correctly through
      // SqlTrendStore itself, which is what a user actually experiences.
      // Reopening the same path while `migrated` is still open reuses the
      // live sqflite single-instance connection rather than performing a
      // second real open, so this triggers no further migration attempt.
      final store = await SqlTrendStore.open(path: dbPath, reconcile: false);
      addTearDown(store.close);
      final points = await store.pointsForRun(runId);
      expect(points, hasLength(1));
      expect(points.single.testId, 'tb_alu_add');
      expect(points.single.status, TestStatus.pass);
      expect(points.single.runtime, const Duration(milliseconds: 4321));
      expect(
        points.single.startedAt,
        DateTime.fromMillisecondsSinceEpoch(startedAt, isUtc: true),
      );
    },
  );
}

void main() {
  setUpAll(ensureCruxSqliteFfiInitialized);

  final policy = SqlTrendStore.debugOpenPolicy;

  group('SimCrux trends.db: data survives every historical upgrade', () {
    for (final testCase in cruxMigrationFixtureCases(
      runner: policy.runner,
      recovery: policy.recovery,
      onRecovery: policy.onRecovery,
      fixturesByVersion: {
        for (var v = 1; v <= policy.runner.latestVersion; v++) v: _fixture(v),
      },
    )) {
      test(testCase.name, testCase.run);
    }
  });
}
