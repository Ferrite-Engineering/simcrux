// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the docked cross-probe side-panel is currently shown.
///
/// App-global and ephemeral: a single panel, one visibility flag shared across
/// tabs (a global provider read from a per-tab scope falls through to this root
/// instance). Deliberately NOT persisted in [AppSettings] — the panel is a
/// transient inspector surface, like a dialog used to be, not a saved layout
/// preference. Toggled by the toolbar `Icons.sensors` button, the
/// `openCrossProbePanel` action, and the panel's own close chevron.
final NotifierProvider<CrossProbeVisibilityNotifier, bool>
crossProbeVisibleProvider =
    NotifierProvider<CrossProbeVisibilityNotifier, bool>(
      CrossProbeVisibilityNotifier.new,
    );

/// Notifier backing [crossProbeVisibleProvider]. Hidden by default.
class CrossProbeVisibilityNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  /// Flips the panel between shown and hidden (toolbar button / action).
  void toggle() => state = !state;

  /// Sets the panel visibility explicitly (panel close chevron → false).
  // ignore: use_setters_to_change_properties
  void set({required bool visible}) => state = visible;
}
