// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

/// The kind of trend regression an alert was emitted for.
///
/// Detection rules live in the Pro overlay's
/// `RegressionAlertDetector`, and the acknowledged-alerts store and the
/// banner that renders alerts are Pro overlay code too; nothing in the
/// open core reads this model.
enum TrendAlertKind {
  /// Recent runs are slower on average than the prior window by
  /// more than the configured threshold.
  runtimeRegression,

  /// A test has failed in N consecutive recent runs after passing
  /// in the prior M runs.
  newPersistentFailure,

  /// A test's pass/fail pattern is alternating frequently across
  /// the recent window — a mild-flakiness complement to the more
  /// strict `FlakinessScoringEngine` classification.
  flipFlopRunDetected,
}

/// Severity classification of a [TrendAlert].
///
/// Surfaces in the dashboard banner UI as an icon + accent color.
enum TrendAlertSeverity {
  /// Informational — heads-up, no immediate action expected.
  info,

  /// Warning — likely worth investigating soon.
  warning,

  /// Critical — should be triaged immediately.
  critical,
}

/// A single regression-style alert emitted by the alert detector.
///
/// One [TrendAlert] is one row in the dashboard banner. The
/// `detectedAtRunId` field anchors the alert to a specific run so
/// the banner's "Show trend" action can pre-populate the chart with
/// the right run highlighted; `firstObservedAtRunId` lets the UI
/// label whether this is a new or persistent observation.
@immutable
class TrendAlert {
  /// Creates a [TrendAlert].
  const TrendAlert({
    required this.kind,
    required this.severity,
    required this.detectedAtRunId,
    required this.firstObservedAtRunId,
    this.testId,
    this.suiteId,
    this.baselineValue,
    this.currentValue,
    this.deltaPercent,
  });

  /// The detection rule that fired.
  final TrendAlertKind kind;

  /// Severity assignment by the rule that fired.
  final TrendAlertSeverity severity;

  /// `TestSpec.id` of the affected test. Null when the alert
  /// targets a suite-wide metric.
  final String? testId;

  /// Suite name of the affected suite. Null when the alert is
  /// per-test rather than suite-level.
  final String? suiteId;

  /// Numeric baseline value (e.g., prior-window mean runtime). The
  /// unit depends on [kind]: ms for runtime regressions, count for
  /// failure / flip-flop alerts.
  final double? baselineValue;

  /// Numeric current value (e.g., recent-window mean runtime).
  final double? currentValue;

  /// Percent change from baseline → current as a fraction
  /// (`+0.5` = 50% slower). Null when the alert kind has no
  /// meaningful percentage delta.
  final double? deltaPercent;

  /// `TestRun.id` of the most recent run that contributed to the
  /// alert firing.
  final String detectedAtRunId;

  /// `TestRun.id` of the earliest run in the current alert series
  /// — same as [detectedAtRunId] for new alerts; carries the
  /// first run in the series when the alert has persisted across
  /// multiple ingest cycles.
  final String firstObservedAtRunId;

  /// Stable identity used by the acknowledged-alerts repository.
  ///
  /// Acknowledgements need a key that survives across ingest cycles:
  /// "this kind of alert on this test/suite". Re-emissions of the
  /// same alert use the same fingerprint so an acknowledged alert
  /// doesn't re-surface every refresh.
  String get fingerprint => '${kind.name}::${suiteId ?? ''}::${testId ?? ''}';

  /// Returns a copy with the given fields replaced. Pass
  /// `clearBaseline` / `clearCurrent` / `clearDelta` to null out a
  /// previously set numeric field.
  TrendAlert copyWith({
    TrendAlertKind? kind,
    TrendAlertSeverity? severity,
    String? testId,
    String? suiteId,
    double? baselineValue,
    double? currentValue,
    double? deltaPercent,
    String? detectedAtRunId,
    String? firstObservedAtRunId,
    bool clearBaseline = false,
    bool clearCurrent = false,
    bool clearDelta = false,
  }) {
    return TrendAlert(
      kind: kind ?? this.kind,
      severity: severity ?? this.severity,
      testId: testId ?? this.testId,
      suiteId: suiteId ?? this.suiteId,
      baselineValue: clearBaseline
          ? null
          : (baselineValue ?? this.baselineValue),
      currentValue: clearCurrent ? null : (currentValue ?? this.currentValue),
      deltaPercent: clearDelta ? null : (deltaPercent ?? this.deltaPercent),
      detectedAtRunId: detectedAtRunId ?? this.detectedAtRunId,
      firstObservedAtRunId: firstObservedAtRunId ?? this.firstObservedAtRunId,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TrendAlert &&
          other.kind == kind &&
          other.severity == severity &&
          other.testId == testId &&
          other.suiteId == suiteId &&
          other.baselineValue == baselineValue &&
          other.currentValue == currentValue &&
          other.deltaPercent == deltaPercent &&
          other.detectedAtRunId == detectedAtRunId &&
          other.firstObservedAtRunId == firstObservedAtRunId;

  @override
  int get hashCode => Object.hash(
    kind,
    severity,
    testId,
    suiteId,
    baselineValue,
    currentValue,
    deltaPercent,
    detectedAtRunId,
    firstObservedAtRunId,
  );

  @override
  String toString() =>
      'TrendAlert($kind/$severity, '
      'test: $testId, suite: $suiteId, '
      'baseline: $baselineValue → current: $currentValue, '
      'detectedAt: $detectedAtRunId)';
}
