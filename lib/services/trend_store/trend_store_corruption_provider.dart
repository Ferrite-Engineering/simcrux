// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/models/trend_store_corruption_notice.dart';

/// Holds the trend database's corruption notice for the session, if any.
///
/// One-time on purpose, exactly like LintCrux's ingest-failure signal. A file
/// is quarantined once — the next open finds the fresh database and succeeds —
/// so there is no stream of notices to coalesce; what there is instead is a
/// notice that must not evaporate before the user sees it. It stays until
/// dismissed.
///
/// **Why a notice is mandatory rather than nice.** `CruxDbRecovery.renameAside`
/// moves the damaged file aside and opens an empty one in its place, and an
/// empty trend chart is indistinguishable from "no runs recorded yet". Without
/// this, a user whose history was quarantined would see a product that looks
/// like it is working and has silently stopped showing them a year of data.
/// `CruxSqliteOpenPolicy` refuses to be constructed without a listener for
/// this reason; this is where SimCrux's listener puts what it is told.
class TrendStoreCorruptionNotifier
    extends Notifier<TrendStoreCorruptionNotice?> {
  @override
  TrendStoreCorruptionNotice? build() => null;

  /// Records [notice] unless one is already pending dismissal.
  ///
  /// First-wins rather than last-wins: with the Pro per-project family, two
  /// projects opened in one session could each quarantine a file, and the
  /// first is the one the user has not yet been told about.
  void report(TrendStoreCorruptionNotice notice) {
    if (state != null) return;
    state = notice;
  }

  /// Clears the pending notice, re-arming the signal.
  void dismiss() => state = null;
}

/// The pending trend-database corruption notice, or `null` when the store
/// opened cleanly (the common case, and the only case before this shipped).
///
/// Rendered by the App Diagnostics dialog's recovery card, which is also where
/// the rebuild-from-`results.ndjson` action lives.
final NotifierProvider<
  TrendStoreCorruptionNotifier,
  TrendStoreCorruptionNotice?
>
trendStoreCorruptionProvider =
    NotifierProvider<TrendStoreCorruptionNotifier, TrendStoreCorruptionNotice?>(
      TrendStoreCorruptionNotifier.new,
    );
