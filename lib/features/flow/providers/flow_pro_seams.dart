// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
