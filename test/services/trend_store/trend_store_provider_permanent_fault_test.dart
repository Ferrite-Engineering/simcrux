// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_sqlite/crux_sqlite.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/services/trend_store/sql_trend_store.dart';
import 'package:simcrux/services/trend_store/trend_store_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A fault that cannot be retried away must not be retried.
///
/// Riverpod 3 retries a failed provider ten times with exponential backoff and
/// holds `AsyncLoading` — *carrying* the error — the whole time. Measured on a
/// permanently failing open: 11 attempts, and the state only became
/// `AsyncError` after ~40 seconds. For those forty seconds App Diagnostics'
/// correct error arm was unreachable and the panel showed a bare "…", for
/// exactly the faults that have something actionable to say.
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('simcrux_permfault_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Writes a database stamped at a schema version this build cannot read.
  Future<void> seedSkewedDatabase() async {
    sqfliteFfiInit();
    final raw = await databaseFactoryFfi.openDatabase(
      p.join(tmp.path, 'trends.db'),
    );
    await raw.execute(
      'PRAGMA user_version = ${SqlTrendStore.latestSchemaVersion + 5}',
    );
    await raw.close();
  }

  ProviderContainer containerFor() {
    final container = ProviderContainer(
      overrides: [
        trendStoreDirectoryOverrideProvider.overrideWithValue(tmp.path),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('a version skew settles into AsyncError at once, not in 40s', () async {
    await seedSkewedDatabase();
    final container = containerFor();

    await expectLater(
      container.read(trendStoreProvider.future),
      throwsA(isA<CruxSchemaVersionSkewException>()),
    );

    // The discriminator, and why this is a state assertion rather than a
    // stopwatch: under the default policy the first retry lands at 200 ms and
    // the state stays AsyncLoading until ~38.6 s, so anything checked here
    // would read AsyncLoading. Under the fixed policy the first failure is
    // final.
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(
      container.read(trendStoreProvider),
      isA<AsyncError<TrendStoreForTest>>(),
      reason: 'still AsyncLoading means the permanent fault is being retried',
    );
  });

  test('the error the user is shown names what to do about it', () async {
    await seedSkewedDatabase();
    final container = containerFor();

    Object? captured;
    try {
      await container.read(trendStoreProvider.future);
    } on Object catch (e) {
      captured = e;
    }

    // App Diagnostics renders `'$error'` verbatim in both its trend-store and
    // schema sections, so this string IS the user-facing text. A skew is the
    // one fault whose message names an action; before the retry fix it
    // reached only a console.
    final text = '$captured';
    expect(text, contains('schema v'));
    expect(text, contains('Open it with'));
    expect(text, contains('Nothing has been modified'));
  });

  test('the dependent providers settle too, not one after another', () async {
    await seedSkewedDatabase();
    final container = containerFor();

    for (final read in <Future<Object?> Function()>[
      () => container.read(trendStorageStatsProvider.future),
      () => container.read(trendSchemaInfoProvider.future),
    ]) {
      await expectLater(read(), throwsA(isA<CruxSchemaVersionSkewException>()));
    }

    // Each dependent is its own FutureProvider, so without the shared policy
    // each would serve its own ten-retry sentence on top of the open's.
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(
      container.read(trendStorageStatsProvider),
      isA<AsyncError<Object?>>(),
    );
    expect(container.read(trendSchemaInfoProvider), isA<AsyncError<Object?>>());
  });
}

/// Alias so the `isA<AsyncError<…>>` above names the provider's value type
/// without importing the interface purely for a type argument.
typedef TrendStoreForTest = Object;
