// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_flow/crux_flow.dart';
import 'package:meta/meta.dart';
import 'package:simcrux/services/flow/flow_run_reading.dart';

/// A comparison operator of `--fail-on` (the `crux_findings` set).
enum FlowGateOp {
  /// `<`.
  lt('<'),

  /// `<=`.
  le('<='),

  /// `==`.
  eq('=='),

  /// `>=`.
  ge('>='),

  /// `>`.
  gt('>');

  const FlowGateOp(this.symbol);

  /// The operator as written.
  final String symbol;

  /// Whether `value <op> limit` holds.
  bool holds(num value, num limit) => switch (this) {
    lt => value < limit,
    le => value <= limit,
    eq => value == limit,
    ge => value >= limit,
    gt => value > limit,
  };
}

/// One gate threshold: the run **fails** when `metric <op> limit` holds.
@immutable
class FlowThreshold {
  /// Creates the threshold.
  const FlowThreshold({
    required this.name,
    required this.metric,
    required this.op,
    required this.limit,
  });

  /// `--fail-on-wns <ns>`: aggregated `timing__setup__wns` below the limit.
  factory FlowThreshold.wns(double ns) => FlowThreshold(
    name: 'fail-on-wns',
    metric: 'timing__setup__wns',
    op: FlowGateOp.lt,
    limit: ns,
  );

  /// `--fail-on-hold-wns <ns>`.
  factory FlowThreshold.holdWns(double ns) => FlowThreshold(
    name: 'fail-on-hold-wns',
    metric: 'timing__hold__wns',
    op: FlowGateOp.lt,
    limit: ns,
  );

  /// `--fail-on-fmax-below <MHz>`.
  factory FlowThreshold.fmaxBelow(double mhz) => FlowThreshold(
    name: 'fail-on-fmax-below',
    metric: 'fmax__achieved__mhz',
    op: FlowGateOp.lt,
    limit: mhz,
  );

  /// `--fail-on '<metric><op><value>'`. Throws [FormatException] when
  /// [spec] is not that shape.
  factory FlowThreshold.parse(String spec) {
    final match = _pattern.firstMatch(spec.trim());
    final value = match == null ? null : double.tryParse(match.group(3)!);
    if (match == null || value == null || !value.isFinite) {
      throw FormatException(
        "--fail-on expects '<metric><op><value>' with op one of "
        '< <= == >= > (got "$spec")',
      );
    }
    final op = FlowGateOp.values.firstWhere((o) => o.symbol == match.group(2));
    return FlowThreshold(
      name: 'fail-on',
      metric: match.group(1)!,
      op: op,
      limit: value,
    );
  }

  static final RegExp _pattern = RegExp(
    r'^([A-Za-z0-9_:.\-]+?)\s*(<=|>=|==|<|>)\s*(-?[0-9]+(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?)$',
  );

  /// The option that set it.
  final String name;

  /// The metric key compared.
  final String metric;

  /// The operator.
  final FlowGateOp op;

  /// The limit.
  final double limit;

  /// `metric<op>limit`.
  String get expression => '$metric${op.symbol}$limit';
}

/// One threshold, evaluated.
@immutable
class FlowThresholdResult {
  /// Creates the result.
  const FlowThresholdResult({required this.threshold, this.value});

  /// The threshold.
  final FlowThreshold threshold;

  /// The metric's value, or null when the run does not have it.
  final num? value;

  /// Whether the metric is missing.
  bool get missing => value == null;

  /// Whether the threshold failed.
  bool get failed =>
      value != null && threshold.op.holds(value!, threshold.limit);
}

/// The gate's decision.
enum FlowGateDecision {
  /// Every threshold met, or no thresholds and the verdict is `met`.
  met,

  /// A threshold failed, a critical metric got worse than the baseline, or
  /// (with neither) the verdict is `violated`.
  violated,

  /// The verdict is not one a gate can read (stopped, not run,
  /// unrecognised), or a threshold's metric is missing.
  couldNotEvaluate,
}

/// The gate's evaluation of one run.
@immutable
class FlowGateOutcome {
  /// Creates the outcome.
  const FlowGateOutcome({
    required this.decision,
    required this.thresholds,
    this.baselineWorse = const <MetricComparison>[],
  });

  /// The decision.
  final FlowGateDecision decision;

  /// Every threshold, evaluated.
  final List<FlowThresholdResult> thresholds;

  /// The critical metrics that got worse than the baseline.
  final List<MetricComparison> baselineWorse;
}

/// Decides `simcrux flow gate` for [reading] against [thresholds] and an
/// optional [baseline] metric set.
///
/// A run whose verdict is `stopped`, `notRun` or `unrecognised` cannot be
/// gated. Otherwise, with no thresholds and no baseline the verdict
/// decides; with either, they decide instead (a nextpnr run that missed an
/// aggressive constraint still passes `--fail-on-fmax-below 50` when it
/// reached 60 MHz). A threshold whose metric is missing makes the run
/// unevaluable, which outranks a failed threshold.
FlowGateOutcome evaluateFlowGate(
  FlowReading reading,
  List<FlowThreshold> thresholds, {
  Map<String, Object?>? baseline,
}) {
  final metrics = reading.run.metrics;
  final results = <FlowThresholdResult>[
    for (final t in thresholds)
      FlowThresholdResult(
        threshold: t,
        value: switch (metrics[t.metric]) {
          final num v when v.isFinite => v,
          _ => null,
        },
      ),
  ];
  final worse = baseline == null
      ? const <MetricComparison>[]
      : <MetricComparison>[
          for (final c in MetricDiff.fromMetrics(
            baseline,
            metrics,
            table: librelaneMetricsV1,
          ).comparisons)
            if (c.critical && c.better == false) c,
        ];
  final verdict = reading.verdict;
  final unreadable =
      verdict == FlowVerdict.stopped ||
      verdict == FlowVerdict.notRun ||
      verdict == FlowVerdict.unrecognised;
  final FlowGateDecision decision;
  if (unreadable || results.any((r) => r.missing)) {
    decision = FlowGateDecision.couldNotEvaluate;
  } else if (thresholds.isEmpty && baseline == null) {
    decision = verdict == FlowVerdict.met
        ? FlowGateDecision.met
        : FlowGateDecision.violated;
  } else if (results.any((r) => r.failed) || worse.isNotEmpty) {
    decision = FlowGateDecision.violated;
  } else {
    decision = FlowGateDecision.met;
  }
  return FlowGateOutcome(
    decision: decision,
    thresholds: results,
    baselineWorse: worse,
  );
}
