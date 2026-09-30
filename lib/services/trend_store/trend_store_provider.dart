// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:simcrux/domain/interfaces/trend_store.dart';
import 'package:simcrux/domain/models/trend_schema_info.dart';
import 'package:simcrux/domain/models/trend_storage_stats.dart';
import 'package:simcrux/services/trend_store/sql_trend_store.dart';
import 'package:simcrux/services/trend_store/trend_store_corruption_provider.dart';

/// Overridable directory hint for tests. When null (the default) the
/// trend store opens at `<applicationSupportDirectory>/trends.db`.
final Provider<String?> trendStoreDirectoryOverrideProvider = Provider<String?>(
  (ref) => null,
);

/// Resolves the absolute path to `trends.db` for the running platform.
///
/// On desktop/mobile (the only place the io [SqlTrendStore] runs),
/// this is `applicationSupportDirectory/trends.db`. Tests override
/// [trendStoreDirectoryOverrideProvider] to redirect into a temp
/// directory.
final FutureProvider<String> trendStorePathProvider = FutureProvider<String>((
  ref,
) async {
  final override = ref.watch(trendStoreDirectoryOverrideProvider);
  if (override != null) {
    return p.join(override, 'trends.db');
  }
  final dir = await getApplicationSupportDirectory();
  return p.join(dir.path, 'trends.db');
});

/// Retry policy shared by the trend-store providers, and by Pro providers
/// that await them.
///
/// A permanent open fault is final on the first attempt; everything else
/// keeps Riverpod's default backoff.
///
/// Applied to the DEPENDENTS as well as to the open itself, and that is the
/// part that is easy to miss: each of them is its own `FutureProvider`, so a
/// dependency that settles into `AsyncError` makes their bodies throw, and
/// each would then serve its own ten-retry sentence on top of the open's.
/// One provider fixed in isolation would have moved the forty seconds rather
/// than removed them.
Duration? trendStoreRetry(int retryCount, Object error) =>
    SqlTrendStore.isPermanentOpenFault(error)
    ? null
    : ProviderContainer.defaultRetry(retryCount, error);

/// The active [TrendStore].
///
/// Opens the SQLite database lazily on first read. On web the
/// underlying implementation is a no-op stub; the API stays uniform
/// so the dashboard renders trend surfaces without per-platform
/// branching.
///
/// A `trends.db` whose bytes are not a readable SQLite database is renamed
/// aside and a fresh one opened in its place — never deleted — and the notice
/// is routed to [trendStoreCorruptionProvider] so the App Diagnostics recovery
/// card can say so and offer the rebuild. Before that wiring the same file
/// surfaced as a raw `DatabaseException` in this provider's error state, which
/// took the whole dashboard down and told the user nothing they could act on.
final FutureProvider<TrendStore> trendStoreProvider =
    FutureProvider<TrendStore>(
      (ref) async {
        final path = await ref.watch(trendStorePathProvider.future);
        final store = await SqlTrendStore.open(
          path: path,
          onCorruption: ref.read(trendStoreCorruptionProvider.notifier).report,
        );
        ref.onDispose(store.close);
        return store;
      },
      // A version skew, a failed migration and a failed pre-upgrade backup are
      // all answers that will not change on the next attempt. Riverpod's
      // default retries a failed provider ten times with exponential backoff,
      // and holds `AsyncLoading` *carrying* the error throughout — so App
      // Diagnostics' correct `AsyncError` arm was unreachable for ~40 seconds
      // (measured: 11 opens) and the panel showed a bare "…" for exactly the
      // faults that have something to tell the user. Returning null here makes
      // the first failure final, so the error arm renders at once.
      //
      // Everything else keeps the default. A transient fault — a locked file,
      // a directory not yet created, `SQLITE_BUSY` — is precisely what the
      // backoff is for, and corruption never reaches this at all: the open
      // policy quarantines and reopens, so the open succeeds.
      retry: trendStoreRetry,
    );

/// Storage snapshot of the active [TrendStore] — data-point / run
/// counts, oldest/newest timestamps, approximate on-disk size.
///
/// Consumed by the App Diagnostics dialog's Trend Store section and
/// the Pro Retention settings surface. Re-computed whenever the
/// dialog re-reads it; callers that need live updates after a prune
/// invalidate this provider explicitly.
final FutureProvider<TrendStorageStats> trendStorageStatsProvider =
    FutureProvider<TrendStorageStats>((ref) async {
      final store = await ref.watch(trendStoreProvider.future);
      return await store.storageStats();
    }, retry: trendStoreRetry);

/// What `trends.db` records about its own schema — version, the build that
/// last migrated it, and the tail of its migration ledger.
///
/// Read from the shared `schema_meta` shape `package:crux_sqlite` writes into
/// every Crux SQLite database. Rendered by the App Diagnostics dialog, where
/// it answers the question a support conversation actually opens with: *which
/// build produced this file?*
///
/// [TrendSchemaInfo.absent] for a database written before schema v4 (every
/// existing install, until the launch that migrates it) and on web, where
/// there is no database. Absence is a state the dialog renders, not an error.
///
/// Asks the store rather than testing its type. The type test this replaces
/// (`if (store is! SqlTrendStore) return TrendSchemaInfo.absent;`) was wrong
/// for every Pro seat: the overlay wraps the SQL store in a
/// `HybridTrendStore`, so the check fell through to "absent" and the dialog
/// told each of them their database predated schema v4 — on files that build
/// had written at v4 minutes earlier. `storageStats` in the sibling provider
/// above never had the bug precisely because it asks.
final FutureProvider<TrendSchemaInfo> trendSchemaInfoProvider =
    FutureProvider<TrendSchemaInfo>((ref) async {
      final store = await ref.watch(trendStoreProvider.future);
      // Stores with no file behind them inherit the interface default, which
      // is `absent` — the same answer, reached by asking rather than guessing.
      return await store.schemaInfo();
    }, retry: trendStoreRetry);
