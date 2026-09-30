// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Opener callback for a Pro trend-tracking screen.
///
/// Receives the [BuildContext] anchored at the invocation site so
/// the Pro overlay can decide whether to push a route, mount a
/// modal dialog, or attach the screen to the active pane.
///
/// The optional [testId] / [suiteId] hints let the per-test and
/// per-suite chart openers pre-populate their pickers when the
/// caller has a specific target (e.g. the dashboard row context
/// menu's "Show trend for this test" entry).
typedef TrendScreenOpener =
    void Function(
      BuildContext context, {
      String? testId,
      String? suiteId,
    });

/// Plain callback that takes no extra hints. Used by the calendar
/// heatmap and the retention policy settings, which open the same
/// screen regardless of context.
typedef TrendScreenOpenerSimple = void Function(BuildContext context);

/// Extension-point seam for the Pro per-test trend chart screen.
///
/// **Open-core default.** Returns `null` — the chart is a Pro
/// feature; the menu / command palette entry remains visible so
/// users discover the capability, but firing it is a no-op until
/// the Pro overlay registers the opener.
///
/// **Pro override.** The Pro overlay's `proOverrides` list replaces
/// this provider with a callback that pushes the
/// `PerTestTrendChartScreen` route via the active navigator and
/// layers a `FeatureGate.isAvailable(LicenseTier.pro, ref)` check
/// on top so post-beta openCore builds see the upgrade dialog.
final Provider<TrendScreenOpener?> perTestTrendChartOpenerProvider =
    Provider<TrendScreenOpener?>((ref) => null);

/// Extension-point seam for the Pro per-suite trend chart screen.
///
/// Mirrors [perTestTrendChartOpenerProvider]. See its docs for the
/// open-core default vs. Pro override convention.
final Provider<TrendScreenOpener?> perSuiteTrendChartOpenerProvider =
    Provider<TrendScreenOpener?>((ref) => null);

/// Extension-point seam for the Pro calendar heatmap screen.
final Provider<TrendScreenOpenerSimple?> calendarHeatmapOpenerProvider =
    Provider<TrendScreenOpenerSimple?>((ref) => null);

/// Extension-point seam for the Pro retention policy settings.
final Provider<TrendScreenOpenerSimple?> retentionPolicySettingsOpenerProvider =
    Provider<TrendScreenOpenerSimple?>((ref) => null);
