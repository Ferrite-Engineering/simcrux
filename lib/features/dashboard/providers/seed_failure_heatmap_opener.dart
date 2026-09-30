// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Opener callback for the Pro Seed Failure Heatmap screen.
///
/// Receives a [BuildContext] anchored at the screen / dialog
/// invocation site so the override can decide whether to push a new
/// route, open a modal dialog, or attach the screen to the active
/// pane.
typedef SeedFailureHeatmapOpener = void Function(BuildContext context);

/// Extension-point seam the Pro overlay uses to mount the Seed
/// Failure Heatmap screen.
///
/// **Open-core default.** Returns `null` — the heatmap is a Pro
/// feature; the menu / command-palette entry remains visible in an
/// open-core build (so users discover the capability) but firing it
/// is a no-op until the Pro overlay registers the opener.
///
/// **Pro override.** The Pro overlay's `proOverrides` list replaces
/// this provider with a callback that pushes the
/// `SeedFailureHeatmapScreen` route via the active navigator. The
/// callback layers a `FeatureGate.isAvailable(LicenseTier.pro,
/// ref)` check on top so post-beta openCore builds see the upgrade
/// dialog rather than the screen.
///
/// **Why a callback-typed provider rather than a widget builder.**
/// The same opener is consumed from multiple call sites (toolbar
/// button, command palette dispatch, per-row context menu). A
/// callback-typed provider keeps the navigation logic in one place
/// — the Pro override decides whether to dialog / route / pane the
/// screen, and every caller dispatches identically.
final Provider<SeedFailureHeatmapOpener?> seedFailureHeatmapOpenerProvider =
    Provider<SeedFailureHeatmapOpener?>(
      (ref) => null,
    );
