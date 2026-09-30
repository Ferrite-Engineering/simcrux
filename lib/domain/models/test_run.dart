// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/test_result.dart';

/// A single regression run — one user-initiated invocation of
/// `JobScheduler.submit` with a set of `TestSpec`s.
///
/// Holds the snapshot of which tests ran, their results so far (the
/// `currentRun` of `ResultStore` updates this incrementally as tests
/// finish), and the run-level totals. The run is `running` until
/// every spec has either reported a result or been cancelled.
@immutable
class TestRun {
  /// Creates a [TestRun].
  TestRun({
    required this.id,
    required this.startedAt,
    required this.testIds,
    this.finishedAt,
    List<TestResult>? results,
  }) : results = List<TestResult>.unmodifiable(results ?? const []);

  /// Creates a [TestRun] whose [results] is the caller's list *as-is*
  /// — no defensive copy.
  ///
  /// Hot-path constructor for `InMemoryResultStore`, which emits one
  /// `currentRun` event per finished test: with the copying default
  /// constructor a 10k-test run performs ~10k list copies of up to
  /// 10k elements (O(n²)). The store instead passes a read-only
  /// *live view* (`UnmodifiableListView`) over its growing result
  /// list, so each emission is O(1).
  ///
  /// Contract for callers: the backing list may only ever be
  /// *appended to* (never mutated in place / reordered / truncated),
  /// and consumers must not iterate it across `await` gaps while the
  /// run is still in flight (single-threaded synchronous iteration —
  /// the dashboard's map/filter/sort pipeline — is safe). Completed
  /// runs are re-published through [copyWith], which snapshots via
  /// the copying default constructor.
  const TestRun.view({
    required this.id,
    required this.startedAt,
    required this.testIds,
    required this.results,
    this.finishedAt,
  });

  /// Stable run identifier (UUID). Persists in SQLite as the
  /// foreign-key target for every result row.
  final String id;

  /// When the user / CLI triggered the run (UTC).
  final DateTime startedAt;

  /// When the final result was received, or null while the run is
  /// still in flight.
  final DateTime? finishedAt;

  /// The `TestSpec.id` values that were scheduled. Pre-recorded so
  /// the dashboard can show "X of Y tests complete" even before the
  /// first result lands.
  final List<String> testIds;

  /// Results collected so far. Ordered by completion time, not by
  /// `testIds` order.
  final List<TestResult> results;

  /// Whether the run has finished (every test has either a result or
  /// was cancelled).
  bool get isFinished => finishedAt != null;

  /// Wall-clock runtime so far. Returns the elapsed time if the run
  /// is still in flight.
  Duration runtime({DateTime? now}) {
    return (finishedAt ?? now ?? DateTime.now()).difference(startedAt);
  }

  /// Number of tests whose result matches [status]. Pass / fail / etc.
  /// counts as displayed in the dashboard's run summary.
  int countOf(TestStatus status) =>
      results.where((r) => r.status == status).length;

  /// Returns a copy with the given fields replaced.
  TestRun copyWith({
    String? id,
    DateTime? startedAt,
    DateTime? finishedAt,
    List<String>? testIds,
    List<TestResult>? results,
  }) {
    return TestRun(
      id: id ?? this.id,
      startedAt: startedAt ?? this.startedAt,
      finishedAt: finishedAt ?? this.finishedAt,
      testIds: testIds ?? this.testIds,
      results: results ?? this.results,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! TestRun) return false;
    if (other.id != id) return false;
    if (other.startedAt != startedAt) return false;
    if (other.finishedAt != finishedAt) return false;
    if (other.testIds.length != testIds.length) return false;
    for (var i = 0; i < testIds.length; i++) {
      if (other.testIds[i] != testIds[i]) return false;
    }
    if (other.results.length != results.length) return false;
    for (var i = 0; i < results.length; i++) {
      if (other.results[i] != results[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    id,
    startedAt,
    finishedAt,
    Object.hashAll(testIds),
    Object.hashAll(results),
  );
}
