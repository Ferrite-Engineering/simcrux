// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/domain/interfaces/trend_store.dart';
import 'package:simcrux/domain/models/trend_store_rebuild_report.dart';

/// Web stub for [TrendStoreRebuilder].
///
/// The web build is the read-only dashboard viewer: there is no local
/// `results.ndjson` to read and no SQLite database to write, so there is
/// nothing here to rebuild. It reports each archive as
/// [TrendStoreArchiveOutcome.unreadable] rather than throwing, so a caller
/// that reaches it renders an honest empty result instead of a crash — and
/// rather than reporting success, which would claim a recovery that did not
/// happen.
class TrendStoreRebuilder {
  /// Creates a [TrendStoreRebuilder].
  const TrendStoreRebuilder();

  /// Always recovers nothing. See the class docs.
  Future<TrendStoreRebuildReport> rebuild({
    required TrendStore store,
    required List<String> archivePaths,
  }) async {
    return TrendStoreRebuildReport(
      archives: <TrendStoreArchiveResult>[
        for (final path in archivePaths)
          TrendStoreArchiveResult(
            path: path,
            outcome: TrendStoreArchiveOutcome.unreadable,
            runId: null,
            pointsRecovered: 0,
            rowsSkipped: 0,
            runWasComplete: false,
            detail: 'the web build has no local trend database',
          ),
      ],
    );
  }
}
