// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_sqlite/crux_sqlite.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/core/app_info/build_info.dart';
import 'package:simcrux/services/trend_store/sql_migrations.dart';
import 'package:simcrux/services/trend_store/sql_trend_store_io.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The shared `schema_meta` shape as `trends.db` actually carries it.
///
/// `crux_sqlite` owns the shape and its tests own the mechanism; these are the
/// SimCrux-side facts: that the store adopted it, at which version, that an
/// existing regression history survives the upgrade, and that what a user's
/// file cannot know is recorded as unknown rather than guessed.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('simcrux_schema_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String dbPath() => p.join(tmp.path, 'trends.db');

  /// Builds a `trends.db` stuck at [version] by opening it with a truncated
  /// prefix of the real migration list — the historical schema by definition,
  /// because migrations are frozen.
  Future<void> seedAtVersion(int version, {int runs = 0}) async {
    final policy = CruxSqliteOpenPolicy(
      runner: CruxMigrationRunner(
        storeName: 'SimCrux trend store',
        migrations: simcruxTrendStoreMigrations.take(version).toList(),
        identity: CruxAppIdentity(
          product: SimCruxBuildInfo.productName,
          appVersion: '0.7.0',
        ),
      ),
      recovery: CruxDbRecovery.refuse,
    );
    final db = await policy.open(dbPath());
    for (var i = 0; i < runs; i++) {
      await db.insert('runs', <String, Object?>{
        'id': 'r$i',
        'started_at': 1700000000000 + i,
        'config_hash': 'cfg',
        'trigger_kind': 'manual',
        'total_tests': 1,
        'metadata': '{}',
      });
    }
    await db.close();
  }

  test('the trend store is at schema v4 and v4 is the shared shape', () {
    expect(
      SqlTrendStore.latestSchemaVersion,
      4,
      reason:
          'schema_meta landed as the next migration after the '
          'runs(started_at) index',
    );
    expect(
      simcruxTrendStoreMigrations.last.description,
      contains('schema_meta'),
    );
  });

  test('a fresh trends.db records its version, product and build', () async {
    final store = await SqlTrendStore.open(path: dbPath());
    addTearDown(store.close);

    final history = await store.schemaHistory(ledgerLimit: -1);
    final meta = history.meta!;
    expect(meta.schemaVersion, 4);
    expect(meta.product, 'simcrux');
    expect(meta.appVersion, SimCruxBuildInfo.productVersion);
    expect(meta.lastOpenedByAppVersion, SimCruxBuildInfo.productVersion);
    expect(meta.createdAt, isNotNull);
    expect(history.ledger.map((r) => r.version), <int>[4, 3, 2, 1]);
    expect(history.ledger.every((r) => r.appliedAt != null), isTrue);
  });

  group('an existing v3 trends.db', () {
    test('keeps its regression history across the upgrade', () async {
      await seedAtVersion(3, runs: 3);

      final store = await SqlTrendStore.open(path: dbPath());
      addTearDown(store.close);
      expect(await store.runRowCount(), 3);
    });

    test('records what is knowable and marks the rest unknown', () async {
      await seedAtVersion(3, runs: 1);

      final store = await SqlTrendStore.open(path: dbPath());
      addTearDown(store.close);

      final history = await store.schemaHistory(ledgerLimit: -1);
      final meta = history.meta!;
      expect(meta.schemaVersion, 4);
      expect(meta.appVersion, SimCruxBuildInfo.productVersion);
      expect(meta.lastMigratedAt, isNotNull);
      expect(
        meta.createdAt,
        isNull,
        reason:
            'this file predates the ledger. Its creation date is not on disk '
            'anywhere, and stamping "today" would be a fabricated fact in a '
            'column that reads as evidence',
      );

      final backfilled = history.ledger.where((r) => r.isBackfilled);
      expect(
        backfilled.map((r) => r.version),
        <int>[3, 2, 1],
        reason:
            'v1-v3 certainly ran — the file was at v3 — but nothing recorded '
            'when, or by which build',
      );
      expect(
        history.ledger.firstWhere((r) => r.version == 4).appliedByAppVersion,
        SimCruxBuildInfo.productVersion,
        reason: 'v4 is the one migration this build watched',
      );
    });

    test(
      "the backfilled rows still carry each migration's description",
      () async {
        await seedAtVersion(3);

        final store = await SqlTrendStore.open(path: dbPath());
        addTearDown(store.close);

        final history = await store.schemaHistory(ledgerLimit: -1);
        for (final row in history.ledger) {
          expect(row.description, isNotEmpty);
        }
        expect(
          history.ledger.firstWhere((r) => r.version == 1).description,
          'Create runs + test_results tables and their indexes',
          reason:
              'migrations are frozen, so the list still holds the exact text '
              'that ran — the description is knowable even when the timestamp '
              'is not',
        );
      },
    );
  });

  group('schemaInfo, the model the diagnostics dialog renders', () {
    test('maps the recorded file faithfully', () async {
      final store = await SqlTrendStore.open(path: dbPath());
      addTearDown(store.close);

      final info = await store.schemaInfo();
      expect(info.isRecorded, isTrue);
      expect(info.schemaVersion, 4);
      expect(info.migratedByAppVersion, SimCruxBuildInfo.productVersion);
      expect(info.lastOpenedByAppVersion, SimCruxBuildInfo.productVersion);
      expect(info.ledger, hasLength(4));
      expect(info.ledger.first.version, 4);
    });

    test(
      'is absent — not an error — for a database with no schema_meta',
      () async {
        await seedAtVersion(3);

        // Reopen at v3 rather than at HEAD, so the file still predates the
        // ledger. This is what every install looks like to a build mid-rollout.
        final policy = CruxSqliteOpenPolicy(
          runner: CruxMigrationRunner(
            storeName: 'SimCrux trend store',
            migrations: simcruxTrendStoreMigrations.take(3).toList(),
            identity: CruxAppIdentity(
              product: SimCruxBuildInfo.productName,
              appVersion: '0.7.0',
            ),
          ),
          recovery: CruxDbRecovery.refuse,
        );
        final db = await policy.open(dbPath());
        addTearDown(db.close);

        final history = await readCruxSchemaHistory(db);
        expect(history.isPresent, isFalse);
        expect(history.ledger, isEmpty);
      },
    );
  });

  test('a downgrade names the build that wrote the file', () async {
    final store = await SqlTrendStore.open(path: dbPath());
    await store.close();

    final older = CruxSqliteOpenPolicy(
      runner: CruxMigrationRunner(
        storeName: 'SimCrux trend store',
        migrations: simcruxTrendStoreMigrations.take(3).toList(),
        identity: CruxAppIdentity(
          product: SimCruxBuildInfo.productName,
          appVersion: '0.7.0',
        ),
      ),
      recovery: CruxDbRecovery.refuse,
    );

    await expectLater(
      older.open(dbPath()),
      throwsA(
        isA<CruxSchemaVersionSkewException>()
            .having(
              (e) => e.fileAppVersion,
              'fileAppVersion',
              SimCruxBuildInfo.productVersion,
            )
            .having(
              (e) => e.toString(),
              'message',
              contains('version ${SimCruxBuildInfo.productVersion}'),
            ),
      ),
      reason:
          'before schema_meta this refusal could name two numbers and nothing '
          'else. "v4 versus v3" is not something a user can act on; the build '
          'that wrote the file is',
    );
    expect(
      File(dbPath()).existsSync(),
      isTrue,
      reason: 'and it is still a refusal — nothing is deleted',
    );
  });
}
