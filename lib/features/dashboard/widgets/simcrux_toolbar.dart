// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_toolbar/crux_toolbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/core/shortcuts/action_category.dart';
import 'package:simcrux/core/shortcuts/shortcut_bindings_provider.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_context.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_descriptor.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_descriptors.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_actions_extensions.dart';
import 'package:simcrux/features/remote/providers/cxp_discovery_provider.dart';
import 'package:simcrux/features/viewer/providers/right_dock_provider.dart';
import 'package:simcrux/features/workspace/providers/simcrux_action_context_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// SimCrux's binding of the shared [CruxToolbar] to its own action catalog.
///
/// Everything structural — geometry, the `[common] │ [specific]` split, the
/// overflow slot and its edge fade, live-binding tooltips, per-action keys and
/// the semantics region — lives in `crux_toolbar`.
///
/// Three defects go away with the migration:
///
/// - The strip specified **no height at all**, so its size changed between the
///   open-core and Pro builds as the Pro extension injected labelled
///   `TextButton.icon`s next to 18 dp icon buttons.
/// - The cross-probe button poked `crossProbeVisibleProvider` directly instead
///   of dispatching `openCrossProbePanel`, so the toolbar and the menu bar
///   reached the same state by two different paths.
/// - Nothing was ever disabled. Run Regression and Cancel Regression were both
///   permanently lit, so the toolbar never said whether a regression was
///   running, and Re-run Selected Test was clickable with nothing selected.
class SimcruxToolbar extends ConsumerWidget {
  /// Creates the SimCrux toolbar.
  const SimcruxToolbar({this.trailing = const <Widget>[], super.key});

  /// Extra widgets pinned after the overflow slot — the tab shell folds its
  /// debug-only diagnostics affordances in here.
  final List<Widget> trailing;

  void _dispatch(BuildContext context, SimcruxAction action) =>
      Actions.maybeInvoke<SimcruxActionIntent>(
        context,
        SimcruxActionIntent(action),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final ctx = ref.watch(simcruxActionContextProvider);
    final bindings = ref.watch(shortcutBindingsProvider);
    // Dock-aware glyph: lit only when the CXP tab is the one on screen.
    final crossProbeVisible = ref.watch(crossProbeShowingProvider);
    final peerCount = ref.watch(cxpPeersProvider).length;
    final extraActions = ref.watch(extraDashboardActionsProvider);

    return CruxToolbar<SimcruxAction>(
      common: [
        CruxToolbarButtonItem(
          action: SimcruxAction.openProject,
          icon: Icons.folder_open_outlined,
          tooltip: l10n.actionOpenProject,
        ),
        // SimCrux has no session concept, so the canonical Save slot is
        // legitimately absent — the one hole in the common block.
        CruxToolbarButtonItem(
          action: SimcruxAction.closeProject,
          icon: Icons.close,
          tooltip: l10n.actionCloseProject,
        ),
        const CruxToolbarSeparatorItem(),
        CruxToolbarButtonItem(
          action: SimcruxAction.openSearch,
          icon: Icons.search,
          tooltip: l10n.actionOpenSearch,
        ),
        CruxToolbarButtonItem(
          action: SimcruxAction.openCrossProbePanel,
          icon: Icons.sensors_outlined,
          selectedIcon: Icons.sensors,
          isSelected: crossProbeVisible,
          badgeCount: peerCount,
          tooltip: l10n.toolbarToggleCrossProbe,
        ),
        CruxToolbarButtonItem(
          action: SimcruxAction.openSettings,
          icon: Icons.settings_outlined,
          tooltip: l10n.actionOpenSettings,
        ),
      ],
      specific: [
        CruxToolbarButtonItem(
          action: SimcruxAction.importFusesoc,
          icon: Icons.note_add_outlined,
          tooltip: l10n.actionImportFusesoc,
        ),
        const CruxToolbarSeparatorItem(),
        // One control that *is* the run state, replacing the Run and Cancel
        // buttons that used to sit side by side, both permanently lit.
        CruxToolbarWidgetItem(
          id: 'run-stop',
          child: _RunStopButton(
            ctx: ctx,
            onAction: (a) => _dispatch(context, a),
          ),
        ),
        CruxToolbarButtonItem(
          action: SimcruxAction.reRunSelected,
          icon: Icons.replay,
          tooltip: l10n.actionReRunSelected,
        ),
        // Pro extension contributions. They arrive as widgets, so they cannot
        // be item-modelled; the Pro overlay renders them as icon buttons at
        // the shared metrics rather than the labelled TextButton.icons that
        // used to make the bar's height depend on the license tier.
        if (extraActions.isNotEmpty) ...[
          const CruxToolbarSeparatorItem(),
          for (var i = 0; i < extraActions.length; i++)
            CruxToolbarWidgetItem(id: 'pro-$i', child: extraActions[i]),
        ],
      ],
      isEnabled: (action) => isActionEnabled(action, ctx),
      onAction: (action) => _dispatch(context, action),
      shortcutOf: (action) => bindings[action],
      semanticsLabel: l10n.accessibilityToolbarRegion,
      trailing: trailing,
      overflow: CruxToolbarOverflowMenu<SimcruxAction>(
        groups: [
          for (final entry in groupedActionsFor(
            SimcruxActionSurface.menu,
            ctx,
          ).entries)
            if (entry.key != ActionCategory.app)
              CruxOverflowGroup<SimcruxAction>(
                label: entry.key.label(l10n),
                actions: entry.value,
              ),
        ],
        labelOf: (action) => action.label(l10n),
        isEnabled: (action) => isActionEnabled(action, ctx),
        shortcutOf: (action) => bindings[action],
        onAction: (action) => _dispatch(context, action),
        tooltip: l10n.toolbarOverflowActions,
      ),
    );
  }
}

/// The morphing run control, wired to the descriptor table's run gates.
class _RunStopButton extends StatelessWidget {
  const _RunStopButton({required this.ctx, required this.onAction});

  final SimcruxActionContext ctx;
  final void Function(SimcruxAction) onAction;

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    return CruxRunStopButton(
      state: ctx.runInProgress ? CruxRunState.running : CruxRunState.idle,
      metrics: CruxToolbarMetrics.desktop,
      runTooltip: l10n.actionRunRegression,
      cancelTooltip: l10n.actionCancelRegression,
      onRun: isActionEnabled(SimcruxAction.runRegression, ctx)
          ? () => onAction(SimcruxAction.runRegression)
          : null,
      onCancel: isActionEnabled(SimcruxAction.cancelRegression, ctx)
          ? () => onAction(SimcruxAction.cancelRegression)
          : null,
    );
  }
}
