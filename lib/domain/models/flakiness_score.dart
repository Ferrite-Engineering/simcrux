// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/domain/enums/test_status.dart';

/// Per-test flakiness summary computed from a rolling run-history window.
///
/// The score is a single number in `[0.0, 1.0]` where 0.0 means "never
/// failed in this window" and 1.0 means "always failed in this window".
/// A score strictly between 0 and 1 means the test flipped pass/fail at
/// least once — the textbook signal of flakiness.
///
/// The window size (default 50) is configurable per project via
/// [FlakinessConfig]. Recency weighting (also configurable) makes recent
/// runs count more than older ones, so a test that flipped two weeks ago
/// but has passed reliably since then loses its flaky designation
/// gracefully rather than via a sharp drop-off at the window edge.
///
/// **Open-core domain.** The score model lives in open-core so tests
/// for the Pro [FlakinessScoringEngine] can reach it; the engine
/// itself and the dashboard UI are Pro.
@immutable
class FlakinessScore {
  /// Creates a [FlakinessScore].
  const FlakinessScore({
    required this.testId,
    required this.score,
    required this.classification,
    required this.totalRuns,
    required this.passRuns,
    required this.failRuns,
    required this.otherRuns,
    required this.statusFlips,
    required this.lastFailureAt,
    required this.lastSuccessAt,
    required this.windowStart,
    required this.windowEnd,
  }) : assert(
         score >= 0.0 && score <= 1.0,
         'score must be in [0.0, 1.0]',
       );

  /// The test this score belongs to (matches `TestResult.testId`).
  final String testId;

  /// Flakiness in `[0.0, 1.0]`. See class doc for semantics.
  final double score;

  /// Classification derived from [score] and [statusFlips]; see
  /// [FlakyClassification].
  final FlakyClassification classification;

  /// Total runs in the window.
  final int totalRuns;

  /// Number of runs in the window with `TestStatus.pass`.
  final int passRuns;

  /// Number of runs in the window with `TestStatus.fail` or
  /// `TestStatus.timeout`. Timeout-as-fail mirrors the rest of the
  /// CI/dashboard "show only failures" filter.
  final int failRuns;

  /// Runs in the window that classified as neither pass nor fail
  /// (running / skipped / cancelled / vacuous / cover / unknown). They
  /// count toward [totalRuns] but neither numerator nor flips, so a
  /// long skipped streak does not artificially deflate the flakiness
  /// signal.
  final int otherRuns;

  /// Number of pass↔fail status flips in the window. Two consecutive
  /// runs with the same terminal classification → 0 flips.
  final int statusFlips;

  /// Most recent failure in the window, or null when the test has not
  /// failed at all.
  final DateTime? lastFailureAt;

  /// Most recent success in the window, or null when the test has not
  /// passed at all.
  final DateTime? lastSuccessAt;

  /// Inclusive lower bound of the window (`startedAt` of the oldest
  /// run included).
  final DateTime windowStart;

  /// Inclusive upper bound of the window (`startedAt` of the newest
  /// run included).
  final DateTime windowEnd;

  /// Whether the score crosses the configured "flaky" threshold and
  /// has at least one status flip — i.e. should be annotated in the
  /// dashboard and surfaced in the Flaky Tests view.
  bool get isFlaky =>
      classification == FlakyClassification.flaky ||
      classification == FlakyClassification.highlyFlaky;

  /// Equality matches on every field so widget rebuilds compare cleanly.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! FlakinessScore) return false;
    return testId == other.testId &&
        score == other.score &&
        classification == other.classification &&
        totalRuns == other.totalRuns &&
        passRuns == other.passRuns &&
        failRuns == other.failRuns &&
        otherRuns == other.otherRuns &&
        statusFlips == other.statusFlips &&
        lastFailureAt == other.lastFailureAt &&
        lastSuccessAt == other.lastSuccessAt &&
        windowStart == other.windowStart &&
        windowEnd == other.windowEnd;
  }

  @override
  int get hashCode => Object.hash(
    testId,
    score,
    classification,
    totalRuns,
    passRuns,
    failRuns,
    otherRuns,
    statusFlips,
    lastFailureAt,
    lastSuccessAt,
    windowStart,
    windowEnd,
  );

  @override
  String toString() =>
      'FlakinessScore($testId, score=$score, classification=$classification, '
      'pass=$passRuns/$totalRuns, flips=$statusFlips)';
}

/// Coarse classification derived from a [FlakinessScore].
///
/// The classification simplifies the score-and-thresholds tuple into a
/// single enum the dashboard renders as a pill / icon / sort key. The
/// thresholds the engine uses to map score → classification are
/// configurable via [FlakinessConfig].
enum FlakyClassification {
  /// Either no runs in the window or the entire window passed.
  ///
  /// `failRuns == 0` and `statusFlips == 0`.
  stable,

  /// Every run in the window failed. Not flaky — broken.
  ///
  /// `failRuns == passingDenominator` and `statusFlips == 0`.
  consistentlyFailing,

  /// Score below the flaky threshold but with at least one flip in
  /// the window. A test that flipped once a long time ago and has
  /// stabilized since.
  intermittent,

  /// Score in the configured flaky band — the canonical "flaky" test
  /// the dashboard annotates with a flaky icon.
  flaky,

  /// Score above the configured high-flaky threshold — the dashboard
  /// surfaces these as the highest-priority entries in the Flaky Tests
  /// view because they are the most disruptive.
  highlyFlaky,
}

/// Helper for classifying a [TestStatus] as pass / fail / other for
/// flakiness scoring purposes. Lives next to [FlakinessScore] because
/// the dashboard renders the same pass / fail / other rollups in the
/// per-test detail view.
extension TestStatusFlakyCategory on TestStatus {
  /// True for `pass`.
  bool get isFlakyPass => this == TestStatus.pass;

  /// True for `fail` and `timeout` (timeouts roll into failure for
  /// flakiness scoring — they are non-deterministic by nature).
  bool get isFlakyFail => this == TestStatus.fail || this == TestStatus.timeout;
}
