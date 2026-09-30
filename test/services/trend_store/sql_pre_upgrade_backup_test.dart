// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_sqlite/crux_sqlite.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/services/trend_store/sql_migrations.dart';
import 'package:simcrux/services/trend_store/sql_trend_store_io.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// `trends.db` is PRECIOUS — nothing on disk rebuilds a regression history —
/// so it must be snapshotted before any schema upgrade, and no upgrade runs
/// if the snapshot cannot be written
/// (`crux-shared/packages/crux_sqlite/README.md`, rule 4).
///
/// The mechanism itself is `crux_sqlite`'s and is tested exhaustively there.
/// **What this file proves is that SimCrux's store actually opted in**, which
/// is the half no shared test can see. It opts in by declaring its data
/// PRECIOUS rather than by calling anything, so the failure this guards
/// against is somebody "simplifying" the recovery argument to
/// `CruxDbRecovery.recreate` and silently losing both the delete protection
/// and the backup in one edit.
void main() {
  late Directory tmp;

  setUp(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmp = Directory.systemTemp.createTempSync('simcrux_backup_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Builds a `trends.db` stuck at [version] by opening it with a truncated
  /// prefix of the real migration list, then closing it.
  Future<String> seedAtVersion(int version) async {
    final dbPath = '${tmp.path}/trends.db';
    final policy = CruxSqliteOpenPolicy(
      runner: CruxMigrationRunner(
        storeName: 'SimCrux trend store',
        migrations: simcruxTrendStoreMigrations.take(version).toList(),
        identity: CruxAppIdentity(product: 'simcrux', appVersion: '0.8.0'),
      ),
      recovery: CruxDbRecovery.refuse,
    );
    final db = await policy.open(dbPath);
    await db.insert('runs', <String, Object?>{
      'id': 'r1',
      'started_at': 1,
      'config_hash': 'h',
      'trigger_kind': 'manual',
      'total_tests': 1,
      'metadata': '{}',
    });
    await db.close();
    return dbPath;
  }

  test(
    'opening an out-of-date trends.db writes a .pre-v backup first',
    () async {
      // The real store's latest version, so this test keeps working when a
      // migration is appended rather than pinning a number that goes stale.
      final latest = SqlTrendStore.latestSchemaVersion;
      expect(
        latest,
        greaterThan(1),
        reason: 'this test needs at least one upgrade step to exercise',
      );
      final dbPath = await seedAtVersion(latest - 1);
      expect(
        Directory(tmp.path).listSync().where((e) => e.path.endsWith('.bak')),
        isEmpty,
        reason: 'nothing has been upgraded yet',
      );

      final store = await SqlTrendStore.open(path: dbPath);
      addTearDown(store.close);

      final backups = CruxPreUpgradeBackup.backupsFor(dbPath);
      expect(backups, hasLength(1));
      expect(
        backups.single,
        endsWith('.bak'),
        reason: 'the real store opened through the real open path',
      );
      expect(
        backups.single,
        contains('trends.db.pre-v${latest - 1}-'),
        reason: 'named for the version a user would be restoring TO',
      );

      // The snapshot is the pre-migration file, not a copy of the new one.
      final snapshot = await databaseFactory.openDatabase(backups.single);
      final version = await snapshot.rawQuery('PRAGMA user_version');
      final runs = await snapshot.rawQuery('SELECT id FROM runs');
      await snapshot.close();
      expect(version.first.values.first, latest - 1);
      expect(runs.single['id'], 'r1', reason: 'the data is in the backup');
    },
  );

  test('a current trends.db is opened without writing a backup', () async {
    final dbPath = '${tmp.path}/trends.db';
    final created = await SqlTrendStore.open(path: dbPath);
    await created.close();
    final reopened = await SqlTrendStore.open(path: dbPath);
    addTearDown(reopened.close);

    expect(
      CruxPreUpgradeBackup.backupsFor(dbPath),
      isEmpty,
      reason:
          'no upgrade ran, so no snapshot is owed — a backup on every '
          'launch would double the store on disk for nothing',
    );
  });

  test('the trend store declares its data PRECIOUS, which is the opt-in', () {
    // Reading the declaration through the policy the store actually builds.
    final options = SqlTrendStore.debugOpenPolicy;
    expect(options.recovery.isPrecious, isTrue);
    expect(
      options.backsUpBeforeUpgrade,
      isTrue,
      reason:
          'changing the recovery to `recreate` would silently disable '
          'both the delete protection and the pre-upgrade backup',
    );
  });
}
