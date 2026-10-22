// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/flow/gate_level/gls_result.dart';
import 'package:simcrux/services/flow/gate_level/gls_run_info.dart';
import 'package:simcrux/services/flow/gate_level/gls_runner.dart';

/// Opener callback for one of the Pro implementation-flow screens.
///
/// Receives a [BuildContext] anchored at the invocation site so the
/// override can push a route, open a tab-modal dialog or attach the screen
/// to the active pane.
typedef FlowScreenOpener = void Function(BuildContext context);

/// Opens the metric trends across runs (per metric, per corner). Gate
/// `SimcruxGatedFeature.flowTrends`.
typedef FlowTrendsOpener = FlowScreenOpener;

/// Opens the comparison of two runs. Gate `SimcruxGatedFeature.flowCompare`.
typedef FlowCompareOpener = FlowScreenOpener;

/// Opens the PPA dashboard. Gate `SimcruxGatedFeature.flowPpaDashboard`.
typedef FlowPpaOpener = FlowScreenOpener;

/// Opens the design-space sweep view. Gate `SimcruxGatedFeature.flowSweep`.
typedef FlowSweepOpener = FlowScreenOpener;

/// Writes or manages a flow baseline. Gate `SimcruxGatedFeature.flowBaseline`.
typedef FlowBaselineWriter = FlowScreenOpener;

/// What the gate-level triage view opens on: one gate-level result, with the
/// two port dumps its metrics name (`GlsResultView.rtlVcd` and `gateVcd`),
/// the instance scope and the clock, so the view recomputes the per-signal
/// per-cycle differences from the dumps with `GlsTraceComparator`.
@immutable
class GlsTriageTarget {
  /// Creates the target.
  const GlsTriageTarget({required this.result, required this.view});

  /// The gate-level result row.
  final TestResult result;

  /// Its metrics, read.
  final GlsResultView view;
}

/// Opens the gate-level mismatch triage for [target]. Gate
/// `SimcruxGatedFeature.flowGlsTriage`.
typedef FlowGlsTriageOpener =
    void Function(BuildContext context, GlsTriageTarget target);

/// What a gate-level simulation that reads delays runs against: the run, what
/// the user asked, and the tests selected. The SDF seam below is handed this,
/// so a runner that annotates the run's delays starts from exactly the
/// functional simulation's inputs.
@immutable
class GlsRunRequest {
  /// Creates the request.
  const GlsRunRequest({
    required this.info,
    required this.options,
    required this.tests,
  });

  /// The simulated run.
  final GlsRunInfo info;

  /// What the user asked: netlist, strict X, clock, test names.
  final GlsOptions options;

  /// The RTL tests selected.
  final List<TestSpec> tests;
}

/// Runs a delay-annotated gate-level simulation of [request]. Gate
/// `SimcruxGatedFeature.flowSdfGls`. Null in open core, and filled by the Pro
/// overlay only where delay annotation is measured to work.
typedef FlowSdfGlsRunner =
    Future<void> Function(BuildContext context, GlsRunRequest request);

// The five Pro Flow seams, in one file so every one is reachable from the
// action handler that reads the first.
//
// **Open-core default: null.** Each is Pro analysis over runs that are not
// gated at all: the drivers, ingest, the verdict, the metrics and worst-path
// tables, the path detail, the last-run delta chip, the hand-off and the
// gate all render in an unlicensed build. These providers only mount an
// additional screen, never condition a result. Do not move a tier check onto
// a driver, a reader or a table because one lives on the other side of
// these seams.
//
// **Pro override.** The overlay replaces each with a callback that checks
// `proFeatureUnlocked` and either mounts the screen or calls
// `showProUpgradeDialog` with the matching `SimcruxGatedFeature`. With the
// seam null, the action answers "requires SimCrux Pro" through
// `_snackProGated`, a toast on desktop, never a silent no-op.

/// Tools > Flow Metric Trends…
final Provider<FlowTrendsOpener?> flowTrendsOpenerProvider =
    Provider<FlowTrendsOpener?>((ref) => null, name: 'flowTrendsOpener');

/// Tools > Compare Flow Runs…
final Provider<FlowCompareOpener?> flowCompareOpenerProvider =
    Provider<FlowCompareOpener?>((ref) => null, name: 'flowCompareOpener');

/// Tools > PPA Dashboard…
final Provider<FlowPpaOpener?> flowPpaOpenerProvider = Provider<FlowPpaOpener?>(
  (ref) => null,
  name: 'flowPpaOpener',
);

/// Tools > Design-Space Sweep…
final Provider<FlowSweepOpener?> flowSweepOpenerProvider =
    Provider<FlowSweepOpener?>((ref) => null, name: 'flowSweepOpener');

/// Tools > Write Flow Baseline…
final Provider<FlowBaselineWriter?> flowBaselineWriterProvider =
    Provider<FlowBaselineWriter?>((ref) => null, name: 'flowBaselineWriter');

/// Tools > Open Gate-Level Triage…, and the gate-level row's menu. Null in
/// open core: the outcome, the two counts and the waveform are free; the view
/// of which signal differs at which cycle is the Pro analysis.
final Provider<FlowGlsTriageOpener?> flowGlsTriageOpenerProvider =
    Provider<FlowGlsTriageOpener?>((ref) => null, name: 'flowGlsTriageOpener');

/// The delay-annotated gate-level runner. Null in open core and in every
/// build until the Pro overlay fills it.
final Provider<FlowSdfGlsRunner?> flowSdfGlsRunnerProvider =
    Provider<FlowSdfGlsRunner?>((ref) => null, name: 'flowSdfGlsRunner');
