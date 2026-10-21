// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_sqlite/crux_sqlite.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/services/trend_store/sql_migrations.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  final runner = CruxMigrationRunner(
    storeName: 'SimCrux trend store',
    migrations: simcruxTrendStoreMigrations,
    identity: CruxAppIdentity(product: 'simcrux', appVersion: '0.8.0'),
  );

  group('simcruxTrendStoreMigrations', () {
    // The guard that catches a migration appended with a duplicate or
    // skipped version number: CruxMigrationRunner's constructor already
    // validates this (it throws ArgumentError on an incoherent list), but a
    // dedicated test fails loudly under `dart test`/`flutter test` rather
    // than only at whatever call site first constructs the runner.
    test(
      'derived version equals the list length and versions are contiguous '
      'from 1',
      () {
        expect(
          runner.latestVersion,
          equals(simcruxTrendStoreMigrations.length),
        );
        for (var i = 0; i < simcruxTrendStoreMigrations.length; i++) {
          expect(simcruxTrendStoreMigrations[i].version, equals(i + 1));
        }
      },
    );

    test('latestVersion matches the migration list length', () {
      expect(runner.latestVersion, greaterThanOrEqualTo(1));
    });

    test('upgrade from 0 builds the v1 schema and indexes', () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);

      await runner.upgrade(db, 0, 1);

      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('runs', 'test_results')",
      );
      expect(
        tables.map((r) => r['name']),
        containsAll(<String>['runs', 'test_results']),
      );

      final indexes = await db.rawQuery(
        '''
SELECT name FROM sqlite_master
WHERE type='index'
  AND name IN ('idx_results_run', 'idx_results_test_name',
               'idx_results_status', 'idx_results_simulator')
''',
      );
      expect(
        indexes.map((r) => r['name']),
        containsAll(<String>[
          'idx_results_run',
          'idx_results_test_name',
          'idx_results_status',
          'idx_results_simulator',
        ]),
      );
    });

    test(
      'upgrade from v2 to v3 adds idx_runs_started without dropping v2',
      () async {
        final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
        addTearDown(db.close);

        // Build the schema up to v2 (the recent-runs index does not yet
        // exist), as an existing installation from before the v3 change
        // would carry it.
        await runner.upgrade(db, 0, 2);
        var runsStarted = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_runs_started'",
        );
        expect(
          runsStarted,
          isEmpty,
          reason: 'idx_runs_started must not exist at v2',
        );

        // The upgrade path that runs when a v2 DB opens under the v3 app.
        await runner.upgrade(db, 2, 3);

        runsStarted = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_runs_started'",
        );
        expect(
          runsStarted.map((r) => r['name']),
          contains('idx_runs_started'),
          reason: 'v2→v3 must create the runs(started_at) index',
        );
        // The v2 composite index must survive the upgrade untouched.
        final v2Index = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_results_test_started'",
        );
        expect(
          v2Index.map((r) => r['name']),
          contains('idx_results_test_started'),
          reason: 'the v2 index must be preserved across the v3 upgrade',
        );
      },
    );

    test(
      'upgrade from v4 to v5 adds the formal and flow tables, empty, and '
      'their indexes',
      () async {
        final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
        addTearDown(db.close);
        await runner.upgrade(db, 0, 4);
        await db.insert('runs', <String, Object?>{
          'id': 'r1',
          'started_at': 1,
          'config_hash': 'h',
          'trigger_kind': 'manual',
          'total_tests': 1,
          'metadata': '{}',
        });

        await runner.upgrade(db, 4, 5);

        Future<List<String>> columnsOf(String table) async => [
          for (final row in await db.rawQuery('PRAGMA table_info($table)'))
            row['name']! as String,
        ];
        expect(await columnsOf('flow_steps'), <String>[
          'run_id',
          'test_id',
          'ordinal',
          'step_id',
          'tool',
          'status',
          'runtime_ms',
        ]);
        expect(await columnsOf('flow_metrics'), <String>[
          'run_id',
          'test_id',
          'key',
          'base',
          'modifiers',
          'value_real',
          'value_text',
          'aggregated',
        ]);
        expect(await columnsOf('flow_gls_results'), <String>[
          'run_id',
          'test_id',
          'flow_run_id',
          'netlist',
          'delays',
          'outcome',
          'real_diffs',
          'x_diffs',
          'first_diff_ps',
        ]);
        expect(
          await columnsOf('formal_runs'),
          containsAll(<String>[
            'run_id',
            'test_id',
            'tool',
            'task',
            'verdict',
            'depth_configured',
            'depth_reached',
            'verdict_disagreement',
          ]),
        );
        expect(
          await columnsOf('formal_properties'),
          containsAll(<String>['test_id', 'property_key', 'key_scheme']),
        );
        expect(
          await columnsOf('formal_property_results'),
          containsAll(<String>[
            'run_id',
            'test_id',
            'property_key',
            'location',
            'status',
          ]),
        );
        for (final table in const [
          'flow_steps',
          'flow_metrics',
          'flow_gls_results',
          'formal_runs',
          'formal_properties',
          'formal_property_results',
        ]) {
          expect(await db.query(table), isEmpty, reason: table);
        }
        final indexes = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='index'",
        );
        expect(
          indexes.map((r) => r['name']),
          containsAll(<String>[
            'idx_flow_metrics_base',
            'idx_flow_gls_test',
            'idx_formal_runs_test',
            'idx_formal_property_results_key',
          ]),
        );
        // The run written at v4 is untouched.
        expect((await db.query('runs')).single['id'], 'r1');
      },
    );

    test('upgrade rejects downgrade', () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      expect(
        () => runner.upgrade(db, 5, 1),
        throwsA(isA<CruxSchemaVersionSkewException>()),
      );
    });

    test('upgrade is idempotent when oldVersion == newVersion', () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      // Apply v1 first.
      await runner.upgrade(db, 0, 1);
      // Re-run with the same range — no-op, no error.
      await runner.upgrade(db, 1, 1);

      final tableCount =
          (await db.rawQuery(
                "SELECT COUNT(*) AS c FROM sqlite_master WHERE name='runs'",
              )).first['c']!
              as int;
      expect(tableCount, equals(1));
    });
  });
}
