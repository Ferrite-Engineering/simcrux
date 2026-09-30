// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_stats_strip/crux_stats_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/enums/dashboard_view_mode.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_banners_extensions.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_view_mode_provider.dart';
import 'package:simcrux/features/dashboard/widgets/config_load_warnings_banner.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_filter_bar.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_filter_presets_bar.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_heatmap_view.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_results_table.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_view_mode_toggle.dart';
import 'package:simcrux/features/inspector/widgets/run_delta_strip.dart';
import 'package:simcrux/features/workspace/providers/pane_render_stats_provider.dart';

/// The dashboard "center pane" content.
///
/// The tier-1 action toolbar ([SimcruxToolbar]) is **not** here: it was
/// hoisted up to the tab shell ([RegressionTabContent]) as a full-width
/// top-of-window chrome strip that spans every IDE pane, matching the
/// WaveCrux / NetCrux / LintCrux placement. This widget owns only
/// the center pane's own chrome and body.
///
/// Vertical sections, top to bottom:
///
/// - [ConfigLoadWarningsBanner]: the project's load advisories, when any.
/// - Extension-contributed banner widgets from
///   [dashboardBannersProvider] (Pro regression alerts banner;
///   future contributors). Default empty list → no vertical chrome.
/// - [DashboardFilterPresetsBar]: saved filter chips.
/// - [DashboardFilterBar]: free-text + status / suite / simulator
///   multi-selects.
/// - [DashboardViewModeToggle]: table vs. heatmap segmented control.
/// - The active view body — [DashboardResultsTable] or
///   [DashboardHeatmapView] driven by [dashboardViewModeProvider].
/// - [RunDeltaStrip]: counters for what changed vs. the previous
///   run; renders nothing when no prior history exists.
///
/// Run totals are **not** here. A `DashboardStatusBar` used to close this
/// column with the same counts `RegressionStatusBar` shows at the window
/// bottom of the same tab — two strips, one stacked on the other, in two
/// different typographies (14 dp proportional against the shared bar's 11 dp
/// monospace) and two different heights. The window-bottom bar is the
/// suite-wide surface, so it is the survivor; the counts this pane uniquely
/// carried (skipped / timeout / error) moved into it, zero-suppressed.
class DashboardView extends ConsumerWidget {
  /// Creates a [DashboardView].
  const DashboardView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(dashboardViewModeProvider);
    final banners = ref.watch(dashboardBannersProvider);
    final chrome = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The project's own load advisories first: they explain the run
        // this pane is about to show (a sweep that ran once).
        const ConfigLoadWarningsBanner(),
        for (final banner in banners) banner,
        const DashboardFilterPresetsBar(),
        const DashboardFilterBar(),
        const DashboardViewModeToggle(),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        // The chrome's height is not ours to predict: the filter bar wraps
        // its status / suite / simulator chips, so a narrow pane can push it
        // past the pane's whole height — which is how a default-size window
        // ended up with the results table squeezed to nothing under a
        // striped overflow banner. Cap it and let it scroll past the cap;
        // the table keeps the rest either way. Measured out here, not in a
        // LayoutBuilder below: a Column hands its non-flexible children an
        // unbounded height, so a cap read down there would be infinite.
        final chromeCap = constraints.hasBoundedHeight
            ? constraints.maxHeight * _kMaxChromeFraction
            : double.infinity;
        return Column(
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: chromeCap),
              child: SingleChildScrollView(child: chrome),
            ),
            Expanded(
              // Feeds the statistics strip's per-pane render segment.
              // Only the results body is probed — the filter bars
              // and banners above are cheap chrome, and including them would
              // blur the number the segment exists to answer: how long does
              // *this table* take to draw at this row count.
              //
              // Gated on the strip being expanded so the post-frame callback
              // and provider write cost nothing while nobody is looking. The
              // strip lives in RegressionTabContent, outside this subtree —
              // probing it would loop.
              child: CruxPaintTimingProbe(
                enabled: ref.watch(cruxStatsStripExpandedProvider),
                onPaintTimed: (elapsed) => ref
                    .read(paneRenderStatsProvider.notifier)
                    .recordPaint(
                      paintMs: elapsed.inMilliseconds,
                      when: DateTime.now(),
                    ),
                child: switch (mode) {
                  DashboardViewMode.table => const DashboardResultsTable(),
                  DashboardViewMode.heatmap => const DashboardHeatmapView(),
                  DashboardViewMode.inspectorFocused =>
                    const DashboardResultsTable(),
                },
              ),
            ),
            const RunDeltaStrip(),
          ],
        );
      },
    );
  }
}

/// Fraction of the pane the dashboard's filter chrome may occupy before it
/// starts scrolling instead of growing. Half leaves the results table — the
/// surface the pane exists for — at least the other half.
const double _kMaxChromeFraction = 0.5;
