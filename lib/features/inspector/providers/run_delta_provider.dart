// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';
import 'package:simcrux/domain/enums/run_delta_bucket.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/trend_store.dart';
import 'package:simcrux/features/inspector/providers/test_trend_provider.dart';

/// Aggregate delta between the most recent run and the previous run.
///
/// Computed from the [TrendStore]'s `recentDeltas` stream (which
/// emits one [TrendDelta] per test whose terminal status changed
/// vs. the previous run). The aggregation buckets each delta into
/// one of four categories:
///
/// - **new failures**: pass / vacuous → fail / timeout / unknown
/// - **fixed**: fail / timeout / unknown → pass / vacuous
/// - **new tests**: previousStatus null → any
/// - **removed tests**: not directly observable through deltas —
///   computed elsewhere (always zero here).
@immutable
class RunDelta {
  /// Creates a [RunDelta].
  const RunDelta({
    this.newFailures = 0,
    this.fixed = 0,
    this.newTests = 0,
    this.removedTests = 0,
    this.otherChanges = 0,
    this.idsByBucket = const <RunDeltaBucket, Set<String>>{},
  });

  /// Tests that started failing in the most recent run.
  final int newFailures;

  /// Tests that started passing in the most recent run after
  /// previously failing.
  final int fixed;

  /// Tests that have no prior history (first appearance).
  final int newTests;

  /// Tests present in the previous run but absent from this one.
  /// Always zero — computing it needs a cross-run roster diff.
  final int removedTests;

  /// Other status transitions (e.g. timeout → cancelled, or
  /// pass-with-cover → vacuous) that aren't headline failures or
  /// fixes.
  final int otherChanges;

  /// The ids of the tests counted in each bucket, so a counter can narrow the
  /// results table to the tests behind it. A bucket with no tests may be
  /// absent.
  final Map<RunDeltaBucket, Set<String>> idsByBucket;

  /// The ids of the tests counted in [bucket].
  Set<String> idsOf(RunDeltaBucket bucket) =>
      idsByBucket[bucket] ?? const <String>{};

  /// Total number of changes recorded.
  int get totalChanges =>
      newFailures + fixed + newTests + removedTests + otherChanges;
}

/// Materializes [recentTrendDeltasProvider] into the bucketed
/// [RunDelta] consumed by the dashboard's delta strip.
final FutureProvider<RunDelta> runDeltaProvider = FutureProvider<RunDelta>(
  (ref) async {
    final deltas = await ref.watch(recentTrendDeltasProvider.future);
    if (deltas.isEmpty) return const RunDelta();
    var newFailures = 0;
    var fixed = 0;
    var newTests = 0;
    var other = 0;
    final ids = <RunDeltaBucket, Set<String>>{};
    void count(RunDeltaBucket bucket, String testId) =>
        (ids[bucket] ??= <String>{}).add(testId);
    for (final delta in deltas) {
      if (delta.previousStatus == null) {
        newTests++;
        count(RunDeltaBucket.newTests, delta.testId);
        continue;
      }
      final wasFail = _isFailish(delta.previousStatus!);
      final isFail = _isFailish(delta.currentStatus);
      if (!wasFail && isFail) {
        newFailures++;
        count(RunDeltaBucket.newFailures, delta.testId);
      } else if (wasFail && !isFail) {
        fixed++;
        count(RunDeltaBucket.fixed, delta.testId);
      } else {
        other++;
        count(RunDeltaBucket.otherChanges, delta.testId);
      }
    }
    return RunDelta(
      newFailures: newFailures,
      fixed: fixed,
      newTests: newTests,
      otherChanges: other,
      idsByBucket: ids,
    );
  },
);

bool _isFailish(TestStatus status) =>
    status == TestStatus.fail ||
    status == TestStatus.timeout ||
    status == TestStatus.unknown;
