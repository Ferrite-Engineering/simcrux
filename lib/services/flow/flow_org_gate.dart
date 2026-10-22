// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/core/cli/flow_exit_code.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/services/flow/flow_gate.dart';
import 'package:simcrux/services/flow/flow_metric_keys.dart';
import 'package:simcrux/services/flow/flow_run_ingestor.dart';
import 'package:simcrux/services/flow/flow_run_reading.dart';

/// The name an organization threshold carries in reports, where a user's
/// carries the option that set it (`fail-on`).
const String kFlowOrgThresholdName = 'organization';

/// Called once per run an organization gate evaluated: [subject] is the
/// test id (`--ci`) or the run tag (`flow gate`), never a path.
typedef FlowOrgGateHook =
    void Function(FlowGateOutcome outcome, {required String subject});

/// An organization's implementation-flow thresholds, evaluated beside the
/// user's own and reported apart from them.
///
/// The thresholds are the ones `--fail-on` takes, with the same meaning: the
/// run fails one when `metric <op> limit` holds, and a run whose metric is
/// missing, or whose verdict a gate cannot read, cannot be evaluated. The
/// organization's gate never replaces the user's: both are evaluated and
/// [combineExitCode] decides the one exit code.
///
/// Open core builds none: an edition that honours the organization's signed
/// policy resolves the thresholds and hands one to its own `flow gate` and to
/// the desktop `--ci` run, after deciding the licence tier itself.
@immutable
class FlowOrgGate {
  /// Creates the gate.
  const FlowOrgGate({required this.thresholds, this.onEvaluated});

  /// The organization's thresholds.
  final List<FlowThreshold> thresholds;

  /// Called after every evaluation: the audit hook.
  final FlowOrgGateHook? onEvaluated;

  /// Whether there is anything to evaluate.
  bool get isEmpty => thresholds.isEmpty;

  /// Evaluates the thresholds against [reading] and reports it through
  /// [onEvaluated] as [subject].
  FlowGateOutcome evaluate(FlowReading reading, {required String subject}) {
    final outcome = evaluateFlowGate(reading, thresholds);
    onEvaluated?.call(outcome, subject: subject);
    return outcome;
  }

  /// Evaluates every flow result in [results], reading each one's run
  /// directory again for its full metric set ([readRun], the ingestor's
  /// reader unless a test passes one). A flow result whose run cannot be
  /// read cannot be evaluated. Null when [results] holds no flow result.
  Future<FlowGateDecision?> evaluateResults(
    List<TestResult> results, {
    Future<FlowReading?> Function(Map<String, String> metrics)? readRun,
  }) async {
    final read = readRun ?? FlowRunIngestor.readForResult;
    FlowGateDecision? overall;
    for (final result in results) {
      if (!result.metrics.containsKey(FlowMetricKeys.verdict)) continue;
      final reading = await read(result.metrics);
      final FlowGateDecision decision;
      if (reading == null) {
        decision = FlowGateDecision.couldNotEvaluate;
        onEvaluated?.call(
          FlowGateOutcome(
            decision: decision,
            thresholds: <FlowThresholdResult>[
              for (final t in thresholds) FlowThresholdResult(threshold: t),
            ],
          ),
          subject: result.testId,
        );
      } else {
        decision = evaluate(reading, subject: result.testId).decision;
      }
      overall = worse(overall, decision);
    }
    return overall;
  }

  /// The more severe of [a] and [b]: could not evaluate, then violated, then
  /// met.
  static FlowGateDecision worse(FlowGateDecision? a, FlowGateDecision b) {
    if (a == null) return b;
    int rank(FlowGateDecision d) => switch (d) {
      FlowGateDecision.met => 0,
      FlowGateDecision.violated => 1,
      FlowGateDecision.couldNotEvaluate => 2,
    };
    return rank(b) > rank(a) ? b : a;
  }

  /// The exit code once the organization's [decision] joins the user's
  /// [code].
  ///
  /// - The user's `2` stands: a run that could not be read in full is not
  ///   summarised as any finding.
  /// - An organization threshold that could not be evaluated is `2`.
  /// - A violated organization threshold is `3`, whatever the user's own
  ///   thresholds said, so a pipeline can tell the organization's gate from
  ///   its own.
  /// - Otherwise the user's code.
  static int combineExitCode(int code, FlowGateDecision? decision) {
    if (decision == null || decision == FlowGateDecision.met) return code;
    if (code == FlowExitCode.couldNotEvaluate) return code;
    return decision == FlowGateDecision.couldNotEvaluate
        ? FlowExitCode.couldNotEvaluate
        : FlowExitCode.orgThresholdViolated;
  }

  /// The organization's part of a `--json` gate document.
  static Map<String, Object?> json(FlowGateOutcome outcome) =>
      <String, Object?>{
        'decision': outcome.decision.name,
        'thresholds': <Object?>[
          for (final r in outcome.thresholds)
            <String, Object?>{
              'metric': r.threshold.metric,
              'op': r.threshold.op.symbol,
              'limit': r.threshold.limit,
              'value': r.value,
              'result': r.missing ? 'missing' : (r.failed ? 'failed' : 'met'),
            },
        ],
      };

  /// Parses one organization threshold, written as `--fail-on` takes it.
  /// Null when [spec] is not that shape.
  static FlowThreshold? parseThreshold(Object? spec) {
    if (spec is! String) return null;
    try {
      final t = FlowThreshold.parse(spec);
      return FlowThreshold(
        name: kFlowOrgThresholdName,
        metric: t.metric,
        op: t.op,
        limit: t.limit,
      );
    } on FormatException {
      return null;
    }
  }
}
