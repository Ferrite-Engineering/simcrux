// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';

/// In-memory current-run state, derived from a stream of
/// `RegressionEvent`s, and the historical-results query surface.
///
/// Open core ships an in-memory implementation only (indexed by
/// status / suite / simulator / test name). SQLite persistence sits
/// underneath via `TrendStore` — the two interfaces
/// stay separate because the current run's hot path should not block
/// on disk I/O, while the trend queries can.
abstract class ResultStore {
  /// The currently-active `TestRun`, updated as results arrive.
  /// Implementations expose this as a Stream (or a Listenable
  /// equivalent) so the dashboard re-renders incrementally.
  ///
  /// **Lifecycle.** Implementations close this stream when
  /// [recordRunCompletion] fires; subscribers that join *after*
  /// completion receive an immediately-closed stream with no
  /// buffered last-value. Callers that need to display the run
  /// after it completes (modal dialogs opened post-run, lazy
  /// screens) should read [latestRun] synchronously as
  /// `initialData` for any `StreamBuilder`.
  Stream<TestRun> get currentRun;

  /// Snapshot of the most recent `TestRun` value emitted on
  /// [currentRun], retained even after the stream closes via
  /// [recordRunCompletion]. Callers that mount after the run has
  /// finished (the Regression Comparison dialog, the trend chart
  /// screens) read this to populate their initial view without
  /// waiting on a stream that will never emit again.
  TestRun get latestRun;

  /// Append a result to the in-memory current run and mirror it to
  /// the persistence layer.
  Future<void> recordResult(TestResult result);

  /// Mark the run as complete. Records the run summary, flushes any
  /// buffered persistence, and closes the [currentRun] stream.
  Future<void> recordRunCompletion(RunSummary summary);

  /// Query historical runs (for the trend view and the dashboard's
  /// "Recently changed status" surface).
  Stream<TestRun> queryRuns(RunQuery query);

  /// Query historical results filtered by [ResultQuery].
  Stream<TestResult> queryResults(ResultQuery query);
}

/// Run-level summary written when a run completes. Distinct from
/// `TestRun` so the persistence layer can store a tiny digest row
/// even when individual `TestResult`s are pruned.
@immutable
class RunSummary {
  /// Creates a [RunSummary].
  RunSummary({
    required this.runId,
    required this.startedAt,
    required this.finishedAt,
    required Map<TestStatus, int> totalsByStatus,
    this.cancelled = false,
  }) : totalsByStatus = Map<TestStatus, int>.unmodifiable(totalsByStatus);

  /// Run identifier.
  final String runId;

  /// When the run was triggered (UTC).
  final DateTime startedAt;

  /// When the final test reported (UTC).
  final DateTime finishedAt;

  /// Counts of each terminal status. Cardinality fits in a small
  /// row, suitable for the trend store.
  final Map<TestStatus, int> totalsByStatus;

  /// True if the run was cancelled.
  final bool cancelled;

  /// Wall-clock runtime.
  Duration get runtime => finishedAt.difference(startedAt);
}

/// Selector for [ResultStore.queryRuns].
@immutable
class RunQuery {
  /// Creates a [RunQuery].
  const RunQuery({
    this.since,
    this.until,
    this.limit,
    this.projectFilePath,
  });

  /// Lower bound on `TestRun.startedAt`. Inclusive.
  final DateTime? since;

  /// Upper bound on `TestRun.startedAt`. Exclusive.
  final DateTime? until;

  /// Maximum number of runs to return; null = unlimited.
  final int? limit;

  /// Filter to runs of a specific project file. Null = all projects.
  final String? projectFilePath;
}

/// Selector for [ResultStore.queryResults].
@immutable
class ResultQuery {
  /// Creates a [ResultQuery].
  const ResultQuery({
    this.runId,
    this.testIdSubstring,
    this.suiteName,
    this.simulatorId,
    this.status,
    this.minRuntime,
    this.maxRuntime,
    this.limit,
  });

  /// Filter to a specific run.
  final String? runId;

  /// Substring match on the test id.
  final String? testIdSubstring;

  /// Filter to a specific suite.
  final String? suiteName;

  /// Filter to a specific simulator id.
  final String? simulatorId;

  /// Filter to one or more statuses.
  final Set<TestStatus>? status;

  /// Minimum runtime, inclusive.
  final Duration? minRuntime;

  /// Maximum runtime, inclusive.
  final Duration? maxRuntime;

  /// Maximum number of results to return.
  final int? limit;
}
