// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/domain/models/flakiness_config.dart';
import 'package:simcrux/domain/models/flakiness_score.dart';

/// Pro-tier service that classifies tests as flaky based on rolling
/// run history.
///
/// **Extension-point seam.** Open-core ships
/// `NoopFlakyDetectionService` as the default registered against
/// `flakyDetectionServiceProvider`. The Pro overlay registers a
/// concrete `FlakyDetectionServiceImpl` that consumes the
/// open-core [TrendStore] history. Flaky-test detection is the headline
/// Pro feature; the implementation lives entirely in the Pro overlay.
///
/// Feature gating: every call site that surfaces a [FlakinessScore]
/// must also render `SimCruxFeatureTierBadge(LicenseTier.pro)` and gate
/// activation through `FeatureGate.isAvailable(LicenseTier.pro, ref)`.
/// Every call site is Pro overlay code; the open core has none. The noop
/// default returns empty / null for every query, so a surface that reads
/// the seam before the Pro engine is bound renders nothing rather than a
/// misleading "stable".
abstract class FlakyDetectionService {
  /// Returns the [FlakinessScore] for a single [testId] using the
  /// trend-store run history and the supplied [config].
  ///
  /// Returns `null` when the trend store has no recorded runs for
  /// this test (the dashboard then renders no flakiness annotation
  /// rather than a misleading "stable" pill).
  Future<FlakinessScore?> scoreFor({
    required String testId,
    required FlakinessConfig config,
  });

  /// Bulk counterpart to [scoreFor]: scores all of [testIds] against
  /// [config] in one pass, keyed by test id. Tests with no recorded
  /// history are absent from the map (same contract as [scoreFor]
  /// returning null).
  ///
  /// The scheduler primes the Pro flaky-retry cache for every spec in a
  /// run before dispatching the first test. Doing that through
  /// [scoreFor] issued one trend-store query per spec — at 10k specs,
  /// 10k serialized round-trips through the single SQLite worker, all
  /// of it dead time on the run's critical path. Implementations back
  /// this with [TrendStore.recentTrendsFor] so the whole run costs a
  /// bounded number of queries.
  Future<Map<String, FlakinessScore>> scoresForMany({
    required Iterable<String> testIds,
    required FlakinessConfig config,
  });

  /// Returns scores for every test that appears in the trend store
  /// within the [config]'s window, sorted descending by score.
  ///
  /// Used by the Pro "Flaky Tests" view to enumerate flaky tests
  /// across the project. The implementation may stream as scores
  /// become available so the view can render incrementally on large
  /// trend stores.
  Stream<FlakinessScore> scoresForAll({
    required FlakinessConfig config,
  });

  /// Currently-active config for the project. The Pro overlay reads
  /// it from project-scoped settings; the noop returns the defaults.
  FlakinessConfig get currentConfig;
}
