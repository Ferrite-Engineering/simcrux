// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

/// User-tweakable configuration for the Pro flaky-test detection
/// engine.
///
/// Defaults: window of last 50
/// runs, "flaky" threshold at any score in `(0.0, 1.0)` paired with
/// at least one status flip, "highly flaky" at score ≥ 0.4. Defaults
/// are deliberately conservative so the first thing a project sees on
/// upgrading to Pro is "yes, these tests are flaky", not a wall of
/// false positives.
///
/// **Open-core domain.** The config model lives in open-core so the
/// score model and the Pro engine that consumes it can share a type;
/// the dashboard's "Settings → Flaky Tests" editor surface is Pro.
@immutable
class FlakinessConfig {
  /// Creates a [FlakinessConfig].
  const FlakinessConfig({
    this.windowSize = defaultWindowSize,
    this.flakyThreshold = defaultFlakyThreshold,
    this.highlyFlakyThreshold = defaultHighlyFlakyThreshold,
    this.recencyDecay = defaultRecencyDecay,
    this.autoRetryEnabled = false,
    this.autoRetryAttempts = defaultAutoRetryAttempts,
  }) : assert(
         windowSize > 0,
         'windowSize must be positive',
       ),
       assert(
         flakyThreshold > 0.0 && flakyThreshold < 1.0,
         'flakyThreshold must be in (0.0, 1.0)',
       ),
       assert(
         highlyFlakyThreshold > 0.0 && highlyFlakyThreshold < 1.0,
         'highlyFlakyThreshold must be in (0.0, 1.0)',
       ),
       assert(
         highlyFlakyThreshold >= flakyThreshold,
         'highlyFlakyThreshold must be >= flakyThreshold',
       ),
       assert(
         recencyDecay >= 0.0 && recencyDecay <= 1.0,
         'recencyDecay must be in [0.0, 1.0] '
         '(0 = no decay; 1 = only newest run counts)',
       ),
       assert(
         autoRetryAttempts >= 0 && autoRetryAttempts <= 5,
         'autoRetryAttempts must be in [0, 5]',
       );

  /// Default rolling window: last 50 runs.
  static const int defaultWindowSize = 50;

  /// Default minimum score for "flaky": a single flip in 50 runs
  /// scores 1/50 = 0.02. Setting the floor right above that ensures
  /// a long-stable test that flipped once doesn't immediately appear
  /// in the dashboard.
  static const double defaultFlakyThreshold = 0.05;

  /// Default minimum score for "highly flaky": ~20 of 50 runs failed.
  /// At this point the test is more noise than signal and warrants
  /// dedicated attention.
  static const double defaultHighlyFlakyThreshold = 0.40;

  /// Default recency decay factor. 0.0 means raw `failedRuns / totalRuns`;
  /// 1.0 means only the newest run counts. The default 0.3 lightly
  /// favors recent runs without making the score collapse to a binary.
  static const double defaultRecencyDecay = 0.3;

  /// Default auto-retry attempts when [autoRetryEnabled] is on. Three
  /// attempts is the industry consensus for "give the network another
  /// chance" without making CI runtime balloon.
  static const int defaultAutoRetryAttempts = 3;

  /// Number of recent runs to consider when computing the score.
  final int windowSize;

  /// Minimum score at which a test is classified
  /// `FlakyClassification.flaky` (assuming at least one status flip
  /// in the window).
  final double flakyThreshold;

  /// Minimum score at which a test is classified
  /// `FlakyClassification.highlyFlaky`.
  final double highlyFlakyThreshold;

  /// Recency-weighting factor in `[0.0, 1.0]`. The engine uses this
  /// to up-weight more recent runs; `0.0` disables recency weighting
  /// (raw `fails/total`); higher values exponentially favor the most
  /// recent entry.
  final double recencyDecay;

  /// When true, the auto-retry policy re-runs a failing test up to
  /// [autoRetryAttempts] times before recording the result.
  ///
  /// If any retry passes, the test is recorded as `pass` with the
  /// flaky marker set (the engine records the original failure plus
  /// the eventual pass in the trend store so the flakiness score
  /// accurately reflects the flip).
  final bool autoRetryEnabled;

  /// Number of automatic retry attempts (in `[0, 5]`). Ignored when
  /// [autoRetryEnabled] is false.
  final int autoRetryAttempts;

  /// Returns a copy with the given fields replaced.
  FlakinessConfig copyWith({
    int? windowSize,
    double? flakyThreshold,
    double? highlyFlakyThreshold,
    double? recencyDecay,
    bool? autoRetryEnabled,
    int? autoRetryAttempts,
  }) {
    return FlakinessConfig(
      windowSize: windowSize ?? this.windowSize,
      flakyThreshold: flakyThreshold ?? this.flakyThreshold,
      highlyFlakyThreshold: highlyFlakyThreshold ?? this.highlyFlakyThreshold,
      recencyDecay: recencyDecay ?? this.recencyDecay,
      autoRetryEnabled: autoRetryEnabled ?? this.autoRetryEnabled,
      autoRetryAttempts: autoRetryAttempts ?? this.autoRetryAttempts,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! FlakinessConfig) return false;
    return windowSize == other.windowSize &&
        flakyThreshold == other.flakyThreshold &&
        highlyFlakyThreshold == other.highlyFlakyThreshold &&
        recencyDecay == other.recencyDecay &&
        autoRetryEnabled == other.autoRetryEnabled &&
        autoRetryAttempts == other.autoRetryAttempts;
  }

  @override
  int get hashCode => Object.hash(
    windowSize,
    flakyThreshold,
    highlyFlakyThreshold,
    recencyDecay,
    autoRetryEnabled,
    autoRetryAttempts,
  );
}
