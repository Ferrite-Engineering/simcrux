// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/domain/interfaces/flaky_detection_service.dart';
import 'package:simcrux/domain/models/flakiness_config.dart';
import 'package:simcrux/domain/models/flakiness_score.dart';

/// No-op default for the [FlakyDetectionService] extension-point seam.
///
/// Open-core registers this as the default `flakyDetectionServiceProvider`.
/// The Pro overlay replaces it via `proOverrides` with a concrete
/// implementation that consumes the `TrendStore`.
///
/// No open-core surface asks "is this test flaky?"; every reader of the
/// seam is Pro overlay code. Returning `null` / empty here means such a
/// reader sees "no flakiness data available" rather than a misleading
/// "stable" classification when the Pro engine is not bound. The Pro
/// overlay is the only path through which a flaky annotation reaches the
/// UI.
class NoopFlakyDetectionService implements FlakyDetectionService {
  /// Creates a no-op service.
  const NoopFlakyDetectionService();

  @override
  FlakinessConfig get currentConfig => const FlakinessConfig();

  @override
  Future<FlakinessScore?> scoreFor({
    required String testId,
    required FlakinessConfig config,
  }) async => null;

  @override
  Future<Map<String, FlakinessScore>> scoresForMany({
    required Iterable<String> testIds,
    required FlakinessConfig config,
  }) async => const <String, FlakinessScore>{};

  @override
  Stream<FlakinessScore> scoresForAll({
    required FlakinessConfig config,
  }) async* {
    // Intentionally empty — open-core surfaces render no flaky chips.
  }
}
