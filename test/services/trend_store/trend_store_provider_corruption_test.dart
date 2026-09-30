// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/services/trend_store/sql_trend_store.dart';
import 'package:simcrux/services/trend_store/trend_store_corruption_provider.dart';
import 'package:simcrux/services/trend_store/trend_store_provider.dart';

/// The wiring half of trend-store recovery: the production provider, not the store in isolation.
///
/// The store having a recovery path is worth nothing if the provider that
/// actually opens the file does not use it — which is exactly the state this
/// prompt found: `openOrRecover` existed, `trendStoreProvider` called plain
/// `open`, and a corrupt `trends.db` reached the user as a raw
/// `DatabaseException` in a `FutureProvider` error state.
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('simcrux_provrec_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ProviderContainer containerFor() {
    final container = ProviderContainer(
      overrides: [
        trendStoreDirectoryOverrideProvider.overrideWithValue(tmp.path),
      ],
    );
    addTearDown(() async {
      // Windows refuses to delete a directory that holds an open database,
      // and disposing the container starts the store's close without waiting
      // for it. Close it here and wait, before `tearDown` deletes the
      // directory.
      final store = container.read(trendStoreProvider).value;
      if (store is SqlTrendStore) await store.close();
      container.dispose();
    });
    return container;
  }

  test('a corrupt trends.db resolves to a store, not an error state', () async {
    final dbPath = p.join(tmp.path, 'trends.db');
    final garbage = List<int>.generate(4096, (i) => (i * 13) & 0xff);
    File(dbPath).writeAsBytesSync(garbage);
    final container = containerFor();

    // No throw: the dashboard keeps working on a fresh, empty database.
    final store = await container.read(trendStoreProvider.future);
    expect(store, isNotNull);

    final notice = container.read(trendStoreCorruptionProvider);
    expect(
      notice,
      isNotNull,
      reason:
          'an empty chart with no notice is indistinguishable from a project '
          'that has never been run — the notice is the whole point',
    );
    expect(notice!.path, dbPath);
    expect(File(notice.quarantinedPath!).readAsBytesSync(), garbage);
    expect(File(dbPath).existsSync(), isTrue);
  });

  test('a healthy trends.db raises no notice', () async {
    final container = containerFor();

    await container.read(trendStoreProvider.future);

    expect(container.read(trendStoreCorruptionProvider), isNull);
  });
}
