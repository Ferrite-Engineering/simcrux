// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/panel_layout/providers/panel_layout_provider.dart';
import 'package:simcrux/features/remote/providers/cross_probe_visibility_provider.dart';

/// The pinned run-details tab.
const String kRightDockTabDetails = 'details';

/// The docked cross-probe panel tab (on-demand).
const String kRightDockTabCrossProbe = 'crossProbe';

/// The bottom dock's region id (drag-between-docks).
const String kDockRegionBottom = 'bottom';

/// The right dock's region id (drag-between-docks).
const String kDockRegionRight = 'right';

/// Where the CXP tab currently lives (session-only drag override).
class CrossProbeDockRegionNotifier extends Notifier<String> {
  @override
  String build() => kDockRegionRight;

  /// Re-homes the CXP tab into [region].
  // ignore: use_setters_to_change_properties
  void move(String region) => state = region;
}

/// See [CrossProbeDockRegionNotifier].
final crossProbeDockRegionProvider =
    NotifierProvider<CrossProbeDockRegionNotifier, String>(
      CrossProbeDockRegionNotifier.new,
      name: 'crossProbeDockRegionProvider',
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
  final crossProbe = ref.watch(crossProbeVisibleProvider);
  if (tab != null) {
    if (tab == kRightDockTabCrossProbe) {
      if (crossProbe) return tab;
    } else {
      return tab;
    }
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
