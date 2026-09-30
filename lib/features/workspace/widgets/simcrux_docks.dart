// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'package:crux_dock/crux_dock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/dashboard/widgets/log_stream_panel.dart';
import 'package:simcrux/features/dashboard/widgets/test_browser_panel.dart';
import 'package:simcrux/features/inspector/widgets/inspector_pane.dart';
import 'package:simcrux/features/panel_layout/providers/panel_layout_provider.dart';
import 'package:simcrux/features/remote/providers/cross_probe_visibility_provider.dart';
import 'package:simcrux/features/remote/widgets/cross_probe_panel.dart';
import 'package:simcrux/features/viewer/providers/right_dock_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// SimCrux's right dock: Details (pinned) · Cross-Probe (on-demand).
///
/// Brings the CXP panel *inside* the IDE layout — it used to be bolted onto
/// a Row beside the whole layout (fixed 340 px, its own hand-drawn border,
/// not resizable). As a dock tab it shares the right region's splitter,
/// collapse and chrome with Details, exactly like the other three products.
class SimcruxRightDock extends ConsumerWidget {
  /// Creates the right dock.
  const SimcruxRightDock({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final tabNotifier = ref.read(rightDockTabProvider.notifier);

    return CruxDock(
      entries: [
        CruxDockEntry(
          id: kRightDockTabDetails,
          icon: Icons.info_outline,
          label: l10n.dockTabDetails,
          builder: (_) => const InspectorPane(),
        ),
        ..._crossProbeEntry(context, ref, region: kDockRegionRight),
      ],
      activeId: ref.watch(effectiveRightDockTabProvider),
      onSelect: tabNotifier.select,
      onAutoReveal: tabNotifier.reveal,
      dockId: kDockRegionRight,
      onTabMovedIn: (id, _) => _moveTab(ref, id, kDockRegionRight),
      onCollapse: () => ref
          .read(panelLayoutProvider.notifier)
          .setRunDetailsVisible(visible: false),
      collapseTooltip: l10n.dockCollapseTooltip,
      collapseDirection: CruxDockCollapseDirection.right,
      semanticsLabel: l10n.accessibilityRightDockRegion,
    );
  }
}

/// SimCrux's left dock: the test browser, pinned — a "Tests" titled header
/// via the auto-hiding strip.
class SimcruxLeftDock extends ConsumerWidget {
  /// Creates the left dock.
  const SimcruxLeftDock({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    return CruxDock(
      entries: [
        CruxDockEntry(
          id: 'tests',
          icon: Icons.checklist,
          label: l10n.dockTabTests,
          builder: (_) => const TestBrowserPanel(),
        ),
      ],
      onSelect: (_) {},
      onCollapse: () => ref
          .read(panelLayoutProvider.notifier)
          .setTestBrowserVisible(visible: false),
      collapseTooltip: l10n.dockCollapseTooltip,
      collapseDirection: CruxDockCollapseDirection.left,
      semanticsLabel: l10n.accessibilityLeftDockRegion,
    );
  }
}

/// SimCrux's bottom dock: the log-stream pane, pinned — a "Log" titled
/// header via the auto-hiding strip.
class SimcruxBottomDock extends ConsumerWidget {
  /// Creates the bottom dock.
  const SimcruxBottomDock({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    return CruxDock(
      entries: [
        CruxDockEntry(
          id: 'log',
          icon: Icons.article_outlined,
          label: l10n.dockTabLog,
          builder: (_) => const LogStreamPanel(),
        ),
        // A CXP tab dragged down from the right dock.
        ..._crossProbeEntry(context, ref, region: kDockRegionBottom),
      ],
      activeId: ref.watch(bottomDockTabProvider),
      onSelect: (id) => ref.read(bottomDockTabProvider.notifier).select(id),
      dockId: kDockRegionBottom,
      onTabMovedIn: (id, _) => _moveTab(ref, id, kDockRegionBottom),
      onCollapse: () => ref
          .read(panelLayoutProvider.notifier)
          .setLogPanelVisible(visible: false),
      collapseTooltip: l10n.dockCollapseTooltip,
      semanticsLabel: l10n.accessibilityBottomDockRegion,
    );
  }
}

/// The movable CXP entry when it is placed in [region] and the feature is
/// on. Shared by both docks so the tab can never render twice.
List<CruxDockEntry> _crossProbeEntry(
  BuildContext context,
  WidgetRef ref, {
  required String region,
}) {
  final l10n = L10N.of(context);
  if (!ref.watch(crossProbeVisibleProvider) ||
      ref.watch(crossProbeDockRegionProvider) != region) {
    return const [];
  }
  return [
    CruxDockEntry(
      id: kRightDockTabCrossProbe,
      icon: Icons.sensors_outlined,
      label: l10n.dockTabCrossProbe,
      movable: true,
      builder: (_) => const SimCruxCrossProbePanel(),
      onClose: () => ref.read(crossProbeVisibleProvider.notifier).toggle(),
    ),
  ];
}

/// Drop handler: re-home [id] into [region] and reveal it there.
void _moveTab(WidgetRef ref, String id, String region) {
  ref.read(crossProbeDockRegionProvider.notifier).move(region);
  if (region == kDockRegionBottom) {
    ref.read(bottomDockTabProvider.notifier).reveal(id);
  } else {
    ref.read(rightDockTabProvider.notifier).reveal(id);
  }
}

/// Wraps the IDE layout with the JetBrains-style collapsed-region restore
/// bars (suite panel-reopen model): a hidden region leaves a slim strip of
/// its tab icons along its window edge; a click reopens the region with
/// that tab active.
class SimcruxDockRestoreBars extends ConsumerWidget {
  /// Creates the wrapper. [child] is the `CruxIdeLayout`.
  const SimcruxDockRestoreBars({required this.child, super.key});

  /// The IDE layout being wrapped.
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final layout = ref.watch(panelLayoutProvider);
    final notifier = ref.read(panelLayoutProvider.notifier);

    final showLeft = !layout.testBrowserVisible;
    final showRight = !layout.runDetailsVisible;
    final showBottom = !layout.logPanelVisible;

    // One tree shape whatever is collapsed -- picking the wrapper widget by
    // which regions were collapsed (the bare child, a Column, a Row, a Row
    // around a Column) changed the widget type directly above the IDE
    // layout on every dock toggle, so Flutter discarded and rebuilt the
    // whole layout: every dock, the pane scope, the show/hide animation,
    // and dock scroll positions. See WaveCrux's dock_restore_bars.dart for
    // the incident this mirrors. The bars are keyed so one appearing or
    // vanishing is matched by identity and touches nothing but itself.
    return Row(
      children: [
        if (showLeft)
          CruxDockRestoreBar(
            key: const ValueKey('dockRestoreBar.left'),
            edge: CruxDockCollapseDirection.left,
            entries: [
              CruxDockRestoreEntry(
                id: 'tests',
                icon: Icons.checklist,
                label: l10n.dockTabTests,
                onRestore: () => unawaited(
                  notifier.setTestBrowserVisible(visible: true),
                ),
              ),
            ],
            semanticsLabel: l10n.accessibilityLeftDockRegion,
          ),
        Expanded(
          key: const ValueKey('dockRestoreBars.center'),
          child: Column(
            children: [
              Expanded(child: child),
              if (showBottom)
                CruxDockRestoreBar(
                  key: const ValueKey('dockRestoreBar.bottom'),
                  edge: CruxDockCollapseDirection.down,
                  entries: [
                    CruxDockRestoreEntry(
                      id: 'log',
                      icon: Icons.article_outlined,
                      label: l10n.dockTabLog,
                      onRestore: () => unawaited(
                        notifier.setLogPanelVisible(visible: true),
                      ),
                    ),
                    for (final entry in _crossProbeEntry(
                      context,
                      ref,
                      region: kDockRegionBottom,
                    ))
                      CruxDockRestoreEntry(
                        id: entry.id,
                        icon: entry.icon,
                        label: entry.label,
                        onRestore: () => ref
                            .read(bottomDockTabProvider.notifier)
                            .reveal(entry.id),
                      ),
                  ],
                  semanticsLabel: l10n.accessibilityBottomDockRegion,
                ),
            ],
          ),
        ),
        if (showRight)
          CruxDockRestoreBar(
            key: const ValueKey('dockRestoreBar.right'),
            edge: CruxDockCollapseDirection.right,
            entries: [
              CruxDockRestoreEntry(
                id: kRightDockTabDetails,
                icon: Icons.info_outline,
                label: l10n.dockTabDetails,
                onRestore: () => ref
                    .read(rightDockTabProvider.notifier)
                    .reveal(kRightDockTabDetails),
              ),
              for (final entry in _crossProbeEntry(
                context,
                ref,
                region: kDockRegionRight,
              ))
                CruxDockRestoreEntry(
                  id: entry.id,
                  icon: entry.icon,
                  label: entry.label,
                  onRestore: () =>
                      ref.read(rightDockTabProvider.notifier).reveal(entry.id),
                ),
            ],
            semanticsLabel: l10n.accessibilityRightDockRegion,
          ),
      ],
    );
  }
}
