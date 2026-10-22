// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/flow/providers/flow_providers.dart';
import 'package:simcrux/features/panel_layout/providers/panel_layout_provider.dart';
import 'package:simcrux/features/remote/providers/cross_probe_visibility_provider.dart';

/// The pinned run-details tab.
const String kRightDockTabDetails = 'details';

/// The docked cross-probe panel tab (on-demand).
const String kRightDockTabCrossProbe = 'crossProbe';

/// The Flow Runs panel tab (on-demand).
const String kDockTabFlowRuns = 'flowRuns';

/// The bottom dock's region id (drag-between-docks).
const String kDockRegionBottom = 'bottom';

/// The right dock's region id (drag-between-docks).
const String kDockRegionRight = 'right';

/// Every movable dock tab and the region it starts in: the cross-probe
/// panel beside Details, Flow Runs beside the Log, where a run's tables
/// have the window's width.
const Map<String, String> kMovableDockTabHomes = <String, String>{
  kRightDockTabCrossProbe: kDockRegionRight,
  kDockTabFlowRuns: kDockRegionBottom,
};

/// Where each movable dock tab currently lives (session-only drag
/// override), keyed by tab id.
class DockTabRegionNotifier extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() => kMovableDockTabHomes;

  /// Re-homes the tab [id] into [region]. An id that is not a movable tab
  /// moves nothing: a drop names the tab it carried, and only these can be
  /// carried.
  void move(String id, String region) {
    if (!kMovableDockTabHomes.containsKey(id)) return;
    if (region != kDockRegionRight && region != kDockRegionBottom) return;
    state = <String, String>{...state, id: region};
  }
}

/// See [DockTabRegionNotifier].
final NotifierProvider<DockTabRegionNotifier, Map<String, String>>
dockTabRegionProvider =
    NotifierProvider<DockTabRegionNotifier, Map<String, String>>(
      DockTabRegionNotifier.new,
      name: 'dockTabRegionProvider',
    );

/// Where the cross-probe tab lives.
final Provider<String> crossProbeDockRegionProvider = Provider<String>(
  (ref) =>
      ref.watch(dockTabRegionProvider)[kRightDockTabCrossProbe] ??
      kDockRegionRight,
  name: 'crossProbeDockRegionProvider',
);

/// Where the Flow Runs tab lives.
final Provider<String> flowRunsDockRegionProvider = Provider<String>(
  (ref) =>
      ref.watch(dockTabRegionProvider)[kDockTabFlowRuns] ?? kDockRegionBottom,
  name: 'flowRunsDockRegionProvider',
);

/// The bottom dock's active tab id (Log unless a moved-in CXP tab was
/// revealed). Session-only.
class BottomDockTabNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  /// Records [id] as the active tab.
  // ignore: use_setters_to_change_properties
  void select(String id) => state = id;

  /// Reveals [id]: records the choice AND opens the bottom region.
  void reveal(String id) {
    state = id;
    unawaited(
      ref.read(panelLayoutProvider.notifier).setLogPanelVisible(visible: true),
    );
  }
}

/// See [BottomDockTabNotifier].
final bottomDockTabProvider = NotifierProvider<BottomDockTabNotifier, String?>(
  BottomDockTabNotifier.new,
  name: 'bottomDockTabProvider',
);

/// Holds the right dock's active tab id. See [rightDockTabProvider].
class RightDockTabNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  /// Records [id] as the active tab without touching region visibility.
  // Not a setter: an intent method symmetric with [reveal].
  // ignore: use_setters_to_change_properties
  void select(String id) => state = id;

  /// Reveals [id]: records the choice AND opens the right region — the
  /// shared reveal path for the CXP toggle and the dock's auto-reveal.
  void reveal(String id) {
    state = id;
    // Fire-and-forget: the settings mirror behind the layout notifier is
    // async, but the in-memory visibility updates synchronously.
    unawaited(
      ref
          .read(panelLayoutProvider.notifier)
          .setRunDetailsVisible(visible: true),
    );
  }
}

/// The right dock's active tab id. Root-scoped and session-only, matching
/// the CXP visibility flag — the one on-demand feature it selects against.
final rightDockTabProvider = NotifierProvider<RightDockTabNotifier, String?>(
  RightDockTabNotifier.new,
  name: 'rightDockTabProvider',
);

/// The right-dock tab that is (or would be) active, validated against
/// presence. Mirrors the retired arrangement (Cross-Probe beside Details)
/// when no explicit choice exists or the choice went stale.
final Provider<String> effectiveRightDockTabProvider = Provider<String>((ref) {
  final tab = ref.watch(rightDockTabProvider);
  final crossProbe =
      ref.watch(crossProbeVisibleProvider) &&
      ref.watch(crossProbeDockRegionProvider) == kDockRegionRight;
  final flowRuns =
      ref.watch(flowRunsVisibleProvider) &&
      ref.watch(flowRunsDockRegionProvider) == kDockRegionRight;
  if (tab != null) {
    final present = switch (tab) {
      kRightDockTabCrossProbe => crossProbe,
      kDockTabFlowRuns => flowRuns,
      _ => true,
    };
    if (present) return tab;
  }
  if (crossProbe) return kRightDockTabCrossProbe;
  return kRightDockTabDetails;
}, name: 'effectiveRightDockTabProvider');

/// Whether the cross-probe panel is the tab on screen — the toolbar's CXP
/// glyph. Dock-aware: the feature being on *behind* the Details tab does not
/// light the glyph.
final Provider<bool> crossProbeShowingProvider = Provider<bool>((ref) {
  if (!ref.watch(crossProbeVisibleProvider)) return false;
  if (ref.watch(crossProbeDockRegionProvider) == kDockRegionBottom) {
    return ref.watch(panelLayoutProvider.select((s) => s.logPanelVisible));
  }
  return ref.watch(panelLayoutProvider.select((s) => s.runDetailsVisible)) &&
      ref.watch(effectiveRightDockTabProvider) == kRightDockTabCrossProbe;
}, name: 'crossProbeShowingProvider');
