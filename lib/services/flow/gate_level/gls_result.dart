// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/domain/models/flow_run_record.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/services/flow/flow_metric_keys.dart';
import 'package:simcrux/services/flow/gate_level/gls_outcome.dart';

/// A gate-level test result, read back from its metrics ([GlsMetricKeys]).
///
/// The one reader every surface uses (the results table, the inspector, the
/// CLI, the exporters, the trend store, telemetry), so the outcome and the
/// two counts are the same everywhere. Never from the exit code or the
/// status: the metrics hold the outcome the comparison reached.
@immutable
class GlsResultView {
  /// Creates a view.
  const GlsResultView({
    required this.testId,
    required this.outcome,
    required this.netlist,
    required this.simulator,
    required this.strictX,
    this.reason,
    this.realDiffs,
    this.xDiffs,
    this.firstDiffPs,
    this.delays = 'functional',
    this.flowRunId,
    this.runDir,
    this.target = 'other',
    this.pdk,
    this.bannered = false,
    this.versionDiffers = false,
    this.rtlTest,
    this.rtlVcd,
    this.gateVcd,
    this.scope,
    this.clock,
    this.failureMessage,
  });

  /// The view of [result], or null when it is not a gate-level result.
  static GlsResultView? of(TestResult result) {
    final m = result.metrics;
    final outcome = GlsOutcome.fromWireName(m[GlsMetricKeys.outcome]);
    if (outcome == null) return null;
    return GlsResultView(
      testId: result.testId,
      outcome: outcome,
      reason: GlsNotRunReason.fromWireName(m[GlsMetricKeys.reason]),
      netlist: m[GlsMetricKeys.netlist] ?? 'nl',
      delays: m[GlsMetricKeys.delays] ?? 'functional',
      simulator: m[GlsMetricKeys.simulator] ?? 'icarus',
      strictX: m[GlsMetricKeys.strictX] == 'true',
      realDiffs: int.tryParse(m[GlsMetricKeys.realDiffs] ?? ''),
      xDiffs: int.tryParse(m[GlsMetricKeys.xDiffs] ?? ''),
      firstDiffPs: int.tryParse(m[GlsMetricKeys.firstDiffPs] ?? ''),
      flowRunId: m[GlsMetricKeys.flowRun],
      runDir: m[GlsMetricKeys.runDir],
      target: m[GlsMetricKeys.target] ?? 'other',
      pdk: m[GlsMetricKeys.pdk],
      bannered: m[GlsMetricKeys.bannered] == 'true',
      versionDiffers: m[GlsMetricKeys.versionDiffers] == 'true',
      rtlTest: m[GlsMetricKeys.rtlTest],
      rtlVcd: m[GlsMetricKeys.rtlVcd],
      gateVcd: m[GlsMetricKeys.gateVcd],
      scope: m[GlsMetricKeys.scope],
      clock: m[GlsMetricKeys.clock],
      failureMessage: result.failureMessage,
    );
  }

  /// The gate-level test's id.
  final String testId;

  /// How the test came out.
  final GlsOutcome outcome;

  /// Why it did not run, when it did not.
  final GlsNotRunReason? reason;

  /// `nl` or `pnl`.
  final String netlist;

  /// `functional`, or `sdf` for a run annotated from the run's delay file.
  final String delays;

  /// Whether the run was annotated from the run's delay file.
  bool get annotated => delays == 'sdf';

  /// The simulator both runs used.
  final String simulator;

  /// Whether X-asymmetry alone fails the test.
  final bool strictX;

  /// Port-samples with a real difference.
  final int? realDiffs;

  /// Port-samples with only X-asymmetry.
  final int? xDiffs;

  /// The time in picoseconds of the first difference.
  final int? firstDiffPs;

  /// The id the simulated run is recorded under.
  final String? flowRunId;

  /// The simulated run's directory.
  final String? runDir;

  /// The closed telemetry target token.
  final String target;

  /// The run's PDK as LibreLane names it, for display.
  final String? pdk;

  /// Whether the PDK carries the "not measured" banner.
  final bool bannered;

  /// Whether the PDK version found differs from the run's.
  final bool versionDiffers;

  /// The RTL test this reruns.
  final String? rtlTest;

  /// The RTL run's port dump.
  final String? rtlVcd;

  /// The gate run's port dump.
  final String? gateVcd;

  /// The DUT's instance path in the testbench.
  final String? scope;

  /// The clock sampled on.
  final String? clock;

  /// The result's failure message, when it has one.
  final String? failureMessage;

  /// Whether the test passes: the outcome with [strictX].
  bool get passes => outcome.passes(strictX: strictX);

  /// The `flow_gls_results` row for this result, filed under [runId].
  FlowGlsRecord record(String runId) => FlowGlsRecord(
    runId: runId,
    testId: testId,
    flowRunId: flowRunId ?? '',
    netlist: netlist,
    delays: delays,
    outcome: outcome.wireName,
    realDiffs: realDiffs,
    xDiffs: xDiffs,
    firstDiffPs: firstDiffPs,
  );
}

/// The `flow.gls.completed` properties of one gate-level run's [results], or
/// null when none of them is a gate-level result.
///
/// Six properties, the Worker's cap: the run's `outcome` (`differs` when any
/// test differs, else `x_only` when any is X-only, else `equal` when any ran,
/// else `not_run`), the `simulator`, the `netlist`, the `delays`, the closed
/// `target` and the clamped `tests` count. Never a count of differences, a
/// signal name or a cycle.
Map<String, Object?>? glsRunCompletedProperties(
  Iterable<TestResult> results, {
  required int Function(int count) clamp,
}) {
  final views = <GlsResultView>[
    for (final r in results) ?GlsResultView.of(r),
  ];
  if (views.isEmpty) return null;
  final outcome = views.any((v) => v.outcome == GlsOutcome.differs)
      ? GlsOutcome.differs
      : views.any((v) => v.outcome == GlsOutcome.xOnly)
      ? GlsOutcome.xOnly
      : views.any((v) => v.outcome == GlsOutcome.equal)
      ? GlsOutcome.equal
      : GlsOutcome.notRun;
  final first = views.first;
  return <String, Object?>{
    'outcome': outcome.wireName,
    'simulator': first.simulator,
    'netlist': first.netlist,
    'delays': first.delays,
    'target': first.target,
    'tests': clamp(views.length),
  };
}
