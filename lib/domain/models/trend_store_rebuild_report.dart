// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

/// What happened to one `results.ndjson` archive during a rebuild.
enum TrendStoreArchiveOutcome {
  /// The archive's run was replayed into the trend store.
  recovered,

  /// The archive parsed, but its run is already in the trend store, so
  /// nothing was written.
  ///
  /// Not an error and not a silent skip: replaying it would violate the
  /// `test_results` primary key (`<runId>:<testId>`), and *deciding* it is
  /// already there is the only way a rebuild can be run twice without either
  /// throwing or double-counting a run's history.
  alreadyPresent,

  /// The archive carries no `meta` line, so its rows cannot be attributed to
  /// a run.
  ///
  /// A crash before the first flush produces this. Every trend point needs a
  /// run id, and inventing one would fabricate a run that never existed.
  missingRunId,

  /// The archive parsed and had a run id, but contained no replayable result
  /// rows.
  empty,

  /// The archive could not be read at all — missing, unreadable, not NDJSON.
  unreadable,
}

/// One archive's line in a [TrendStoreRebuildReport].
@immutable
class TrendStoreArchiveResult {
  /// Creates a [TrendStoreArchiveResult].
  const TrendStoreArchiveResult({
    required this.path,
    required this.outcome,
    required this.runId,
    required this.pointsRecovered,
    required this.rowsSkipped,
    required this.runWasComplete,
    this.detail,
  });

  /// The archive this line is about.
  final String path;

  /// What happened to it.
  final TrendStoreArchiveOutcome outcome;

  /// The run id read from the archive's `meta` line, or `null`.
  final String? runId;

  /// Trend points written to the store from this archive.
  final int pointsRecovered;

  /// Result rows the archive carried that were deliberately **not** replayed
  /// — rows whose `did_execute` is `false` (the toolchain never launched, so
  /// the live ingest path would have excluded them too) and rows with no test
  /// id.
  final int rowsSkipped;

  /// Whether the archive ended with a `summary` line.
  ///
  /// `false` means the run never finished — the process died mid-run — so the
  /// rebuilt run row keeps a null `finished_at` and reads as `interrupted`,
  /// which is what it was.
  final bool runWasComplete;

  /// Free-text detail for [TrendStoreArchiveOutcome.unreadable].
  final String? detail;
}

/// The result of a rebuild-from-archive pass, as the UI reports it.
///
/// Deliberately arithmetic rather than narrative: the one thing a user must be
/// able to see afterwards is **how much** came back, because the honest answer
/// is "only the runs whose `results.ndjson` you still have" and a reassuring
/// summary would hide that.
@immutable
class TrendStoreRebuildReport {
  /// Creates a [TrendStoreRebuildReport].
  const TrendStoreRebuildReport({required this.archives});

  /// One line per archive the user selected, in the order they were read.
  final List<TrendStoreArchiveResult> archives;

  /// Runs actually written to the store.
  int get runsRecovered => archives
      .where((a) => a.outcome == TrendStoreArchiveOutcome.recovered)
      .length;

  /// Trend points actually written to the store.
  int get pointsRecovered =>
      archives.fold(0, (sum, a) => sum + a.pointsRecovered);

  /// Archives that contributed nothing, for whatever reason.
  int get archivesSkipped => archives.length - runsRecovered;

  /// True when nothing at all was written.
  bool get isEmpty => pointsRecovered == 0;
}
