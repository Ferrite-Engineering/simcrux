// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/features/remote/widgets/cross_probe_row_menu.dart';

/// Builder function the dashboard results table invokes per row to
/// produce an optional trailing widget rendered at the row's far edge.
///
/// Returns `null` to render no trailing widget for the row. Receives
/// a `WidgetRef` so the Pro overlay can read its own providers
/// (e.g. `flakyScoresProvider`) when deciding what to render.
typedef DashboardRowTrailingBuilder =
    Widget? Function(
      WidgetRef ref,
      DashboardRow row,
    );

/// Extension-point seam the Pro overlay uses to annotate dashboard
/// rows with feature-specific trailing widgets (e.g. the flaky-test
/// classification chip the Pro overlay's flaky detection renders).
///
/// **Where it renders.** In the Test cell, right-aligned after the test
/// name, at its natural width; the name ellipsizes before it, and in a
/// column too narrow for both it scales down. There is no reserved column
/// for it, so the table's last column always reaches the pane's edge.
///
/// **Open-core default.** Returns a builder that always returns
/// `null` — open-core surfaces never render a trailing widget. The
/// Pro overlay overrides this provider in `proOverrides` with a
/// builder that consumes the active `flakyDetectionServiceProvider`
/// and returns a tier-badged classification chip for tests that
/// score as flaky.
///
/// **Why a builder, not a widget.** The Pro overlay needs `WidgetRef`
/// access to resolve per-row providers without rebuilding the entire
/// table on every score change. Pushing the builder through a single
/// provider means the table is decoupled from the Pro feature set —
/// adding a second trailing-widget consumer in the future (e.g. a
/// trend-tracking spark) means composing builders here, not editing
/// the table render path.
///
/// **Tier-gating discipline.** Any Pro override of this provider is
/// only registered in the Pro overlay's `proOverrides`, so an
/// open-core build never sees a Pro chip. Open-core consumers of this
/// extension point therefore do not need to bake in `LicenseTier`
/// checks themselves.
final Provider<DashboardRowTrailingBuilder>
dashboardRowTrailingBuilderProvider = Provider<DashboardRowTrailingBuilder>(
  (ref) =>
      (_, _) => null,
);

/// Builder function the dashboard results table invokes per row to
/// build the row's right-click / long-press context menu.
///
/// Returns the list of `PopupMenuEntry` items to render. Open-core
/// default returns the one "Cross-probe to" item. The Pro overlay
/// overrides this provider in `proOverrides`, keeps that item first and adds
/// its own per-row actions after it.
///
/// Receives a `BuildContext` so handlers can show toasts / open
/// dialogs, a `WidgetRef` so they can read the active CXP peer
/// list, the active license tier, etc., and the global [position] the menu
/// opens at, so an item that opens a second menu opens it in the same place.
typedef DashboardRowContextMenuBuilder =
    List<PopupMenuEntry<void>> Function(
      BuildContext context,
      WidgetRef ref,
      DashboardRow row,
      Offset position,
    );

/// Extension-point seam for the per-row context-menu actions of dashboard
/// rows.
///
/// **Open-core default.** One "Cross-probe to" item: the running peer
/// products, each sent the row's test (and its waveform) through the suite's
/// shared cross-probe send. Cross-probing is free on every tier, so a build
/// with no Pro overlay has the menu.
///
/// **Pro override.** The Pro overlay registers a builder that calls
/// [buildCrossProbeRowMenuEntries] first, then adds the re-run and trend
/// entries.
///
/// Like [dashboardRowTrailingBuilderProvider], builder receives a
/// `WidgetRef` so per-row state can be resolved without rebuilding
/// the entire table.
final Provider<DashboardRowContextMenuBuilder>
dashboardRowContextMenuBuilderProvider =
    Provider<DashboardRowContextMenuBuilder>(
      (ref) => buildCrossProbeRowMenuEntries,
    );
