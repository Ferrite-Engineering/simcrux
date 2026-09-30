// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Opener callback for the Pro Regression Comparison screen.
///
/// Receives a [BuildContext] anchored at the screen / dialog
/// invocation site so the override can decide whether to push a new
/// route, open a modal dialog, or attach the screen to the active
/// pane.
typedef RegressionComparisonOpener = void Function(BuildContext context);

/// Extension-point seam the Pro overlay uses to mount the Regression
/// Comparison screen.
///
/// **Open-core default.** Returns `null`. No open-core surface reads
/// this provider — there is no Compare action in the open-core menu,
/// palette or toolbar; the regression-comparison view is a Pro feature
/// and so are both of its entry points.
///
/// **Pro override.** The Pro overlay's `proOverrides` list replaces
/// this provider with a callback that pushes the
/// `RegressionComparisonScreen` route via the active navigator. The
/// callback layers a `FeatureGate.isAvailable(LicenseTier.pro, ref)`
/// check on top so post-beta openCore builds see the upgrade dialog
/// rather than the screen.
///
/// **Why a callback-typed provider rather than a widget builder.**
/// The same opener is consumed from more than one call site — the Pro
/// overlay's "Compare to baseline" toolbar button and its baseline
/// status chip. A callback-typed provider keeps the navigation logic in
/// one place — the Pro override decides whether to dialog / route /
/// pane the screen, and every caller dispatches identically. Mirrors the
/// `seedFailureHeatmapOpenerProvider` shape.
final Provider<RegressionComparisonOpener?> regressionComparisonOpenerProvider =
    Provider<RegressionComparisonOpener?>(
      (ref) => null,
    );
