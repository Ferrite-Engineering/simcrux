// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_status_bar/crux_status_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/providers/regression_runner.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/plugins/status_bar_trailing_widgets_provider.dart';

/// Tab-spanning bottom **status bar** for a regression tab.
///
/// Surfaces the open config's identity — the `simcrux.yaml` file name, which
/// the top title band does not show — always, plus the run summary once the
/// dashboard has results. It adopts the shared cross-suite [CruxStatusBar]
/// chrome so SimCrux's bottom bar matches WaveCrux (the canonical) in height,
/// typography, surface, and border.
///
/// ## The count set
///
/// Total / pass / fail / running render whenever there are results. Skipped,
/// timeout and error render **only when non-zero**: they used to live in a
/// second strip stacked directly above this one, and folding all seven in
/// unconditionally would have made this the widest bar in the suite to show
/// three zeroes in the common case. Suppressing them is the same rule WaveCrux
/// applies to its secondary-cursor, delta and frequency segments — a segment
/// earns its width by having something to say.
///
/// Mounted per-tab as the last child of the regression tab's column, so its
/// reads of [dashboardTotalsProvider] resolve to this tab's scope.
class RegressionStatusBar extends ConsumerWidget {
  /// Creates the regression status bar for the config at [configPath].
  const RegressionStatusBar({required this.configPath, super.key});

  /// Absolute path of the tab's `simcrux.yaml`; its basename is the file
  /// identity segment.
  final String configPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final totals = ref.watch(dashboardTotalsProvider).value;
    // Read the runner directly rather than the root-mirrored action context:
    // this bar is mounted per-tab, so the tab's own runner is what it should
    // report — a run in another tab must not spin this tab's indicator.
    final run = ref.watch(regressionRunnerProvider).value;
    final running = run != null && !run.isFinished;

    return CruxStatusBar(
      segments: [
        if (configPath.isNotEmpty) CruxStatusSegment(p.basename(configPath)),
        if (totals != null) ...[
          CruxStatusSegment('${l10n.dashboardTotalsTotal}: ${totals.total}'),
          _count(l10n.dashboardTotalsPass, totals, TestStatus.pass),
          _count(l10n.dashboardTotalsFail, totals, TestStatus.fail),
          _count(l10n.dashboardTotalsRunning, totals, TestStatus.running),
          // Zero-suppressed — see the class docs.
          ?_countIfAny(l10n.dashboardTotalsSkipped, totals, TestStatus.skipped),
          ?_countIfAny(l10n.dashboardTotalsTimeout, totals, TestStatus.timeout),
          ?_countIfAny(l10n.dashboardTotalsError, totals, TestStatus.unknown),
        ],
      ],
      // Suite grammar: progress first, then the Pro extension slot.
      trailing: [
        if (running)
          CruxStatusBusyIndicator(
            semanticsLabel: l10n.statusBarBusyRegression,
          ),
        ...ref.watch(statusBarTrailingWidgetsProvider),
      ],
    );
  }

  /// The empty-canvas variant: the same chrome, an explicit idle label, and
  /// **no per-tab reads**.
  ///
  /// The bar proper mounts inside `RegressionTabContent`, so with zero tabs
  /// there is nothing to mount it in. Rather than hoist the real bar above
  /// `PaneHost` and feed it the active tab's container — the pattern NetCrux
  /// documents as the cause of its "markNeedsBuild during build" crashes —
  /// the empty state gets its own stateless bar.
  /// The Pro extension slot is carried here too. It is the ONLY provider this
  /// variant reads: `statusBarTrailingWidgetsProvider` is a plain
  /// `Provider<List<Widget>>` the host overrides with a const list, so watching
  /// it stays clear of any per-tab state.
  ///
  /// Without it the empty canvas silently drops the edition badge the Pro
  /// overlay mounts: WaveCrux states the edition on its welcome screen, and
  /// not doing so here would be a suite UI consistency divergence rather
  /// than a platform constraint.
  static Widget idle(BuildContext context) => Consumer(
    builder: (context, ref, _) => CruxStatusBar(
      segments: [CruxStatusSegment(L10N.of(context).statusBarNoConfig)],
      trailing: ref.watch(statusBarTrailingWidgetsProvider),
    ),
  );

  static CruxStatusSegment _count(
    String label,
    DashboardTotals totals,
    TestStatus status,
  ) => CruxStatusSegment('$label: ${totals.countOf(status)}');

  /// The segment for [status], or null when the count is zero.
  static CruxStatusSegment? _countIfAny(
    String label,
    DashboardTotals totals,
    TestStatus status,
  ) => totals.countOf(status) == 0 ? null : _count(label, totals, status);
}
