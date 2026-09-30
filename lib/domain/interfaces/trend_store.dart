// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/retention_policy.dart';
import 'package:simcrux/domain/models/trend_aggregate.dart';
import 'package:simcrux/domain/models/trend_schema_info.dart';
import 'package:simcrux/domain/models/trend_storage_stats.dart';

/// Persistent storage for cross-run trend data.
///
/// The narrow per-test ingest/query surface
/// (`recordTrendPoint`, `recentTrend`, `recentDeltas`) is consumed by
/// the inspector sparkline and the dashboard delta strip. Four
/// additional methods layer on top that the Pro trend
/// charts and regression-alert detector need:
///
/// - [queryDataPoints] — flexible filtered fetch with time-windowing,
///   used by the per-test and per-suite chart screens.
/// - [queryAggregates] — bucketed pass/fail + runtime-percentile
///   summaries, used by the calendar heatmap and the per-suite chart,
///   which roll quarter-hour buckets up into dates.
/// - [applyRetention] — enforces a [RetentionPolicy] in one shot.
/// - [storageStats] — current row count and timestamp span for
///   diagnostics surfaces.
/// - [dataChanged] — emits after every successful mutation so UI
///   consumers can refresh without polling.
///
/// Two further methods exist purely to keep the hot paths off an N+1
/// fan-out against the single-writer SQLite worker:
///
/// - [recentTrendsFor] — bulk [recentTrend], used to prime the Pro
///   flaky-retry cache for a whole run in one query.
/// - [distinctTestIds] — "which tests ran recently", the enumeration
///   surface for cross-test views.
///
/// All of these have default implementations that consult
/// [recentTrend] / [recentDeltas]: every existing concrete trend
/// store keeps working without source changes, and tests / mocks
/// that only need the narrow surface stay unaffected. Concrete
/// stores that can answer the new methods more efficiently
/// (`SqlTrendStore` does, via direct SQL) override them.
abstract class TrendStore {
  /// Record a single test's terminal status at the run granularity.
  /// Conceptually `INSERT INTO trends (run_id, test_id, status,
  /// runtime, started_at)`.
  Future<void> recordTrendPoint(TrendPoint point);

  /// Records many trend points in one call. Semantically identical to
  /// calling [recordTrendPoint] per element; the default does exactly
  /// that so naïve mocks keep working. Stores with a cheaper bulk path
  /// override it — `SqlTrendStore` commits the whole batch in a single
  /// transaction (one fsync, one [dataChanged] emission) because
  /// per-point transactions are prohibitively slow for a hot
  /// per-finished-test ingest path.
  Future<void> recordTrendPoints(Iterable<TrendPoint> points) async {
    for (final point in points) {
      await recordTrendPoint(point);
    }
  }

  /// Stamps [runId]'s `finished_at` so a normally-completed run is not
  /// later mistaken for a crash.
  ///
  /// The GUI ingest path creates run rows lazily via [recordTrendPoint]
  /// (which cannot know a finish time), leaving `finished_at` null for
  /// the run's whole life. Crash reconciliation flags every run with a
  /// null `finished_at` as interrupted, so without this call every
  /// completed GUI run would be flagged at the next open. The runner
  /// invokes this once, at [RegressionFinished], after the final trend
  /// flush. Only runs that never reach this call — genuine crashes —
  /// keep a null `finished_at`.
  ///
  /// The default is a no-op so ephemeral / mock stores are unaffected;
  /// the SQL store overrides it with a single `UPDATE`.
  Future<void> markRunFinished(String runId, DateTime finishedAt) async {}

  /// Return the most recent `limit` trend points for [testId], most
  /// recent first.
  Stream<TrendPoint> recentTrend(String testId, {int limit = 10});

  /// Bulk counterpart to [recentTrend]: returns the most recent
  /// [limit] trend points (newest first) for each of [testIds], keyed
  /// by test id. Tests with no recorded history are absent from the
  /// map — callers must not assume every requested id is a key.
  ///
  /// This exists because the per-test form is an N+1 against the
  /// single-writer SQLite worker: priming a 10k-spec run's flaky-retry
  /// cache issued 10k round-trips before the first test could be
  /// dispatched. Stores backed by a real query engine override this
  /// with one grouped/windowed query; the default implementation below
  /// preserves the old fan-out so naïve mocks keep working.
  Future<Map<String, List<TrendPoint>>> recentTrendsFor(
    Iterable<String> testIds, {
    int limit = 10,
  }) async {
    final out = <String, List<TrendPoint>>{};
    for (final testId in testIds) {
      final points = await recentTrend(testId, limit: limit).toList();
      if (points.isNotEmpty) out[testId] = points;
    }
    return out;
  }

  /// Every distinct test id that appears in the newest [runWindow]
  /// runs, i.e. "the tests this project has actually exercised
  /// recently".
  ///
  /// This is the enumeration surface for cross-test views (the Pro
  /// Flaky Tests panel). It deliberately does **not** go through
  /// [recentDeltas]: that stream yields only tests whose status
  /// *changed* between the newest run and the one before it, so a test
  /// that flaps inside the window but happens to land on the same
  /// status two runs running is invisible to it — precisely the test
  /// a flaky-detection panel most needs to list.
  ///
  /// The default implementation falls back to the (incomplete)
  /// [recentDeltas] enumeration so mocks that predate this method
  /// still return something plausible; every real store overrides it.
  Future<List<String>> distinctTestIds({int runWindow = 10}) async {
    final seen = <String>{};
    await for (final delta in recentDeltas(limit: runWindow)) {
      seen.add(delta.testId);
    }
    return seen.toList();
  }

  /// Returns every persisted trend point recorded for [runId] — one per
  /// test that ran in that run — in a stable order (started-at then
  /// test-id ascending). The list is **empty** when the run has no rows,
  /// which happens when the run was never persisted or has since aged
  /// out under the [RetentionPolicy]; callers must treat empty as
  /// "run no longer available" rather than "run with zero tests".
  ///
  /// This is the reload surface for the Pro regression-comparison view:
  /// it reconstructs a baseline `TestRun` from these points so a saved
  /// baseline run id can be diffed against the current run long after
  /// the baseline's in-memory `ResultStore` is gone.
  ///
  /// The default implementation returns an empty list — ephemeral / mock
  /// stores keep no per-run index — so every existing store keeps
  /// compiling; `SqlTrendStore` overrides it with a `WHERE run_id = ?`
  /// query against the indexed `test_results` table.
  Future<List<TrendPoint>> pointsForRun(String runId) async {
    return const <TrendPoint>[];
  }

  /// Return the most recent terminal status per test across the newest
  /// [limit] runs, so the dashboard can render "newly failing" /
  /// "newly passing" deltas.
  ///
  /// [limit] bounds the comparison window: a test's `previousStatus` is
  /// its newest status among the `limit` most recent runs *excluding*
  /// the newest one, and is null when the test has no result inside
  /// that window. Only tests whose status differs from that previous
  /// value are emitted.
  Stream<TrendDelta> recentDeltas({int limit = 10});

  /// Returns filtered data points ordered by `startedAt` descending
  /// (newest first).
  ///
  /// - [testId] / [suiteId] — narrow by test or suite (suite filter
  ///   may be a no-op on stores that don't index suite names).
  /// - [since] — only include points at or after this UTC timestamp.
  /// - [limit] / [offset] — paginate the result.
  ///
  /// The default implementation falls back to [recentTrend] when
  /// [testId] is supplied, and returns an empty list otherwise. The
  /// SQL store overrides this with parameterized queries against the
  /// indexed `test_results` table.
  Future<List<TrendPoint>> queryDataPoints({
    String? testId,
    String? suiteId,
    DateTime? since,
    int? limit,
    int? offset,
  }) async {
    if (testId == null) return const <TrendPoint>[];
    final points = <TrendPoint>[];
    await for (final p in recentTrend(testId, limit: limit ?? 1000)) {
      if (since != null && p.startedAt.isBefore(since)) continue;
      points.add(p);
    }
    return points;
  }

  /// Returns time-bucketed aggregates for the given [key].
  ///
  /// [bucketSize] controls the bucket width. [since] is optional —
  /// when null, the store returns aggregates over its entire
  /// retained history. Buckets are aligned to the lower bound of
  /// [since] (or the oldest data point when [since] is null).
  ///
  /// A fixed-width bucket is not a calendar day, even a day wide:
  /// [since] decides where it starts, and daylight saving makes a
  /// local day 23 or 25 hours long. A caller that files runs by date
  /// should ask for buckets no wider than 15 minutes from a UTC
  /// midnight and roll them up by the date each one starts on. Every
  /// UTC offset and every daylight-saving shift is a whole number of
  /// quarter hours, so no such bucket straddles a local midnight.
  ///
  /// The default implementation returns an empty list (so naïve
  /// mocks still satisfy the interface); concrete stores override.
  Future<List<TrendAggregate>> queryAggregates({
    required TrendAggregateKey key,
    required Duration bucketSize,
    DateTime? since,
  }) async {
    return const <TrendAggregate>[];
  }

  /// Enforces [policy] on the underlying storage, deleting any
  /// data points that violate the policy's age or count limits.
  ///
  /// Returns the number of data points deleted. The default
  /// implementation does nothing and returns 0 (safe for ephemeral
  /// stores).
  Future<int> applyRetention(RetentionPolicy policy) async => 0;

  /// Snapshot of current storage utilization. The default
  /// implementation returns [TrendStorageStats.empty].
  Future<TrendStorageStats> storageStats() async => TrendStorageStats.empty;

  /// What the backing database records about its own schema — version, the
  /// build that last migrated it, and the tail of its migration ledger.
  ///
  /// On the interface rather than on `SqlTrendStore` alone because a caller
  /// cannot know which store it holds. The App Diagnostics dialog used to ask
  /// `store is! SqlTrendStore` and report [TrendSchemaInfo.absent] otherwise,
  /// which every Pro seat failed: the Pro overlay wraps the SQL store in a
  /// `HybridTrendStore`, so the type test turned "I cannot reach it" into the
  /// confident, wrong "this database was written before schema v4" — on files
  /// the same build had just created at v4. A decorator must be able to
  /// *delegate* this, which is exactly what an interface method allows and a
  /// type test forbids.
  ///
  /// The default is [TrendSchemaInfo.absent], which is the honest answer for
  /// the in-memory and no-op stores: they are real [TrendStore]s with no file
  /// behind them, so there is no schema to report.
  ///
  /// [ledgerLimit] caps how many migration-ledger entries come back.
  Future<TrendSchemaInfo> schemaInfo({int ledgerLimit = 5}) async =>
      TrendSchemaInfo.absent;

  /// Waveform artifact paths recorded against runs *older* than the most
  /// recent [keepRuns] runs — the sweep candidates for
  /// [RetentionPolicy.maxWaveformRuns].
  ///
  /// Returns paths, not deletions: the store knows which runs are stale, but
  /// deleting files is not its job, and a store that unlinked user data as a
  /// side effect of a query would be a hazard to every caller. The sweeper
  /// decides, deletes, and then calls [forgetWaveformPaths].
  ///
  /// The default implementation returns nothing (safe for ephemeral stores,
  /// which own no artifacts).
  Future<List<String>> waveformPathsBeforeRecentRuns(int keepRuns) async =>
      const <String>[];

  /// Clears the recorded waveform path on any result row referencing one of
  /// [paths], after the files themselves are gone.
  ///
  /// Without this the inspector would keep offering "Open waveform" for a
  /// file the sweeper deleted. The result row itself is retained — the run's
  /// pass/fail history outlives its dump.
  Future<void> forgetWaveformPaths(Iterable<String> paths) async {}

  /// Broadcast stream that emits after every ingestion or retention
  /// pruning that mutates the underlying storage. UI consumers
  /// (chart screens, banners, dashboards) listen to refresh without
  /// polling. Implementations that cannot detect mutations expose
  /// a never-emitting stream.
  Stream<void> get dataChanged => const Stream<void>.empty();
}

/// One row in the trend store.
@immutable
class TrendPoint {
  /// Creates a [TrendPoint].
  const TrendPoint({
    required this.runId,
    required this.testId,
    required this.status,
    required this.runtime,
    required this.startedAt,
    this.waveformPath,
    this.suiteName,
  });

  /// The parent run id.
  final String runId;

  /// The test id (matches `TestSpec.id` / `TestResult.testId`).
  final String testId;

  /// Terminal status reported for this test in this run.
  final TestStatus status;

  /// Wall-clock runtime.
  final Duration runtime;

  /// When the run was triggered (UTC).
  final DateTime startedAt;

  /// Where this test's dump was written, when it wrote one.
  ///
  /// Optional, and null for the many rows that never produced one. It is
  /// persisted so the waveform retention sweep can find the dumps belonging
  /// to runs that have aged out — `maxWaveformRuns` is enforced entirely by
  /// reading this column back, and a point that drops it on ingest makes
  /// that policy a silent no-op.
  final String? waveformPath;

  /// The suite this test belongs to, as `simcrux.yaml` names it.
  ///
  /// Optional, and null when the producer has no suite for the test. It is
  /// persisted because the per-suite trend view queries the store by it: a
  /// point that drops it on ingest belongs to no suite, and a suite's chart
  /// built from such points stays empty however many runs are recorded.
  final String? suiteName;
}

/// A "status changed in the latest run vs. the previous run" record.
@immutable
class TrendDelta {
  /// Creates a [TrendDelta].
  const TrendDelta({
    required this.testId,
    required this.currentStatus,
    required this.previousStatus,
    required this.currentRunId,
  });

  /// The test id.
  final String testId;

  /// Status in the most recent run.
  final TestStatus currentStatus;

  /// Status in the previous run; null when this is the test's first
  /// recorded result.
  final TestStatus? previousStatus;

  /// The most recent run's id.
  final String currentRunId;
}
