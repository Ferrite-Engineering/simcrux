// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';
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
    for (final delta in deltas) {
      if (delta.previousStatus == null) {
        newTests++;
        continue;
      }
      final wasFail = _isFailish(delta.previousStatus!);
      final isFail = _isFailish(delta.currentStatus);
      if (!wasFail && isFail) {
        newFailures++;
      } else if (wasFail && !isFail) {
        fixed++;
      } else {
        other++;
      }
    }
    return RunDelta(
      newFailures: newFailures,
      fixed: fixed,
      newTests: newTests,
      otherChanges: other,
    );
  },
);

bool _isFailish(TestStatus status) =>
    status == TestStatus.fail ||
    status == TestStatus.timeout ||
    status == TestStatus.unknown;
