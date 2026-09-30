// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

/// Identifies the dimension a [TrendAggregate] groups by.
enum TrendAggregateKeyKind {
  /// Aggregates rows by test id. `keyId` carries the test name.
  perTest,

  /// Aggregates rows by suite name. `keyId` carries the suite name.
  perSuite,

  /// Aggregates rows globally across every test and suite. `keyId`
  /// is null.
  global,
}

/// Composite key for a [TrendAggregate] query.
///
/// Captures the grouping dimension plus the optional concrete id
/// (test or suite name). Designed for direct hashing in maps that
/// memoize aggregate computations across UI refreshes.
@immutable
class TrendAggregateKey {
  /// Creates a [TrendAggregateKey].
  const TrendAggregateKey({required this.kind, this.id});

  /// Convenience constructor for the per-test grouping.
  const TrendAggregateKey.perTest(String testId)
    : kind = TrendAggregateKeyKind.perTest,
      id = testId;

  /// Convenience constructor for the per-suite grouping.
  const TrendAggregateKey.perSuite(String suiteId)
    : kind = TrendAggregateKeyKind.perSuite,
      id = suiteId;

  /// Convenience constructor for the global grouping.
  const TrendAggregateKey.global()
    : kind = TrendAggregateKeyKind.global,
      id = null;

  /// The dimension to group by.
  final TrendAggregateKeyKind kind;

  /// The concrete test or suite id. Null for [TrendAggregateKeyKind.global].
  final String? id;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TrendAggregateKey && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => 'TrendAggregateKey($kind, $id)';
}

/// A time-bucketed aggregate of trend points.
///
/// Returned from `TrendStore.queryAggregates`. The chart UI consumes
/// these to render time-series visualizations without iterating
/// individual data points: each entry summarizes all runs whose
/// timestamps fall within `[windowStart, windowEnd)`.
///
/// Runtime percentiles (`p50RuntimeMs`, `p95RuntimeMs`, `p99RuntimeMs`)
/// are computed from the underlying data point runtimes; they are
/// null when the bucket contains zero runs.
@immutable
class TrendAggregate {
  /// Creates a [TrendAggregate].
  const TrendAggregate({
    required this.key,
    required this.windowStart,
    required this.windowEnd,
    required this.totalRuns,
    required this.passCount,
    required this.failCount,
    required this.skipCount,
    this.p50RuntimeMs,
    this.p95RuntimeMs,
    this.p99RuntimeMs,
  });

  /// The grouping key this aggregate belongs to.
  final TrendAggregateKey key;

  /// Inclusive lower bound of the time bucket (UTC).
  final DateTime windowStart;

  /// Exclusive upper bound of the time bucket (UTC).
  final DateTime windowEnd;

  /// Total runs in the bucket.
  final int totalRuns;

  /// Runs in the bucket that ended in a pass-like terminal status.
  final int passCount;

  /// Runs in the bucket that ended in a fail-like terminal status
  /// (fail, timeout, unknown).
  final int failCount;

  /// Runs in the bucket that ended skipped or cancelled.
  final int skipCount;

  /// Median runtime in milliseconds. Null when the bucket is empty.
  final int? p50RuntimeMs;

  /// 95th-percentile runtime in milliseconds. Null when the bucket
  /// is empty.
  final int? p95RuntimeMs;

  /// 99th-percentile runtime in milliseconds. Null when the bucket
  /// is empty.
  final int? p99RuntimeMs;

  /// Pass rate as a fraction of [totalRuns]. Returns 0 when the
  /// bucket is empty.
  double get passRate {
    if (totalRuns == 0) return 0;
    return passCount / totalRuns;
  }

  /// Convenience copyWith for tests and ingest pipelines.
  TrendAggregate copyWith({
    TrendAggregateKey? key,
    DateTime? windowStart,
    DateTime? windowEnd,
    int? totalRuns,
    int? passCount,
    int? failCount,
    int? skipCount,
    int? p50RuntimeMs,
    int? p95RuntimeMs,
    int? p99RuntimeMs,
  }) {
    return TrendAggregate(
      key: key ?? this.key,
      windowStart: windowStart ?? this.windowStart,
      windowEnd: windowEnd ?? this.windowEnd,
      totalRuns: totalRuns ?? this.totalRuns,
      passCount: passCount ?? this.passCount,
      failCount: failCount ?? this.failCount,
      skipCount: skipCount ?? this.skipCount,
      p50RuntimeMs: p50RuntimeMs ?? this.p50RuntimeMs,
      p95RuntimeMs: p95RuntimeMs ?? this.p95RuntimeMs,
      p99RuntimeMs: p99RuntimeMs ?? this.p99RuntimeMs,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TrendAggregate &&
          other.key == key &&
          other.windowStart == windowStart &&
          other.windowEnd == windowEnd &&
          other.totalRuns == totalRuns &&
          other.passCount == passCount &&
          other.failCount == failCount &&
          other.skipCount == skipCount &&
          other.p50RuntimeMs == p50RuntimeMs &&
          other.p95RuntimeMs == p95RuntimeMs &&
          other.p99RuntimeMs == p99RuntimeMs;

  @override
  int get hashCode => Object.hash(
    key,
    windowStart,
    windowEnd,
    totalRuns,
    passCount,
    failCount,
    skipCount,
    p50RuntimeMs,
    p95RuntimeMs,
    p99RuntimeMs,
  );
}

/// Helper that computes [TrendAggregate.p50RuntimeMs] /
/// [TrendAggregate.p95RuntimeMs] / [TrendAggregate.p99RuntimeMs] from
/// an unordered list of runtimes (in ms).
///
/// Uses the nearest-rank percentile method (sort ascending, then pick
/// the index `ceil(p * n) - 1` clamped to `[0, n - 1]`). Returns a
/// record of `(p50, p95, p99)` — all null when [runtimes] is empty.
({int? p50, int? p95, int? p99}) computeRuntimePercentiles(
  Iterable<int> runtimes,
) {
  final values = runtimes.toList()..sort();
  if (values.isEmpty) {
    return (p50: null, p95: null, p99: null);
  }
  int pick(double p) {
    final n = values.length;
    final rank = (p * n).ceil() - 1;
    final clamped = rank < 0 ? 0 : (rank >= n ? n - 1 : rank);
    return values[clamped];
  }

  return (p50: pick(0.50), p95: pick(0.95), p99: pick(0.99));
}
