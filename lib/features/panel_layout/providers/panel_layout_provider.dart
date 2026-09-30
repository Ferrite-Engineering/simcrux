// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/models/panel_layout_state.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';

/// Active panel-layout state for the IDE layout.
///
/// A `NotifierProvider` so toggles from the
/// toolbar / menu / keyboard shortcuts mutate state immediately, and
/// drag-to-resize updates from the `panes` package flow back through
/// [PanelLayoutNotifier.setFraction*]. The notifier mirrors every
/// change to disk via [SettingsService.save] so the next launch
/// restores the same layout.
///
/// The notifier defers reading from [appSettingsProvider] until first
/// build; before the settings have loaded, callers see the default
/// state ([PanelLayoutState.new]). Once settings resolve, the notifier
/// rebuilds against the persisted state.
final NotifierProvider<PanelLayoutNotifier, PanelLayoutState>
panelLayoutProvider = NotifierProvider<PanelLayoutNotifier, PanelLayoutState>(
  PanelLayoutNotifier.new,
);

/// Notifier backing [panelLayoutProvider]. Persists mutations via
/// [SettingsService.save].
class PanelLayoutNotifier extends Notifier<PanelLayoutState> {
  @override
  PanelLayoutState build() {
    // Seed from AppSettings the moment they finish loading. Until
    // then we render with the defaults so the layout has a stable
    // first frame.
    final settings = ref.watch(appSettingsProvider);
    return settings.maybeWhen(
      data: (loaded) => loaded.panelLayout,
      orElse: () => const PanelLayoutState(),
    );
  }

  // ── toggles ─────────────────────────────────────────────────────────

  /// Toggles the left test/run browser pane.
  Future<void> toggleTestBrowser() async {
    await _update(
      state.copyWith(testBrowserVisible: !state.testBrowserVisible),
    );
  }

  /// Toggles the right run-details / inspector pane.
  Future<void> toggleRunDetails() async {
    await _update(
      state.copyWith(runDetailsVisible: !state.runDetailsVisible),
    );
  }

  /// Toggles the bottom log-stream pane.
  Future<void> toggleLogPanel() async {
    await _update(
      state.copyWith(logPanelVisible: !state.logPanelVisible),
    );
  }

  // ── explicit set ────────────────────────────────────────────────────

  /// Sets the test browser pane's visibility explicitly. Used by the
  /// command palette + menu actions that need an exact state rather
  /// than a toggle.
  Future<void> setTestBrowserVisible({required bool visible}) async {
    await _update(state.copyWith(testBrowserVisible: visible));
  }

  /// Sets the run details pane's visibility explicitly.
  Future<void> setRunDetailsVisible({required bool visible}) async {
    await _update(state.copyWith(runDetailsVisible: visible));
  }

  /// Sets the log panel's visibility explicitly.
  Future<void> setLogPanelVisible({required bool visible}) async {
    await _update(state.copyWith(logPanelVisible: visible));
  }

  // ── drag-to-resize ──────────────────────────────────────────────────

  /// Updates the test browser pane's width fraction. Clamped to a
  /// safe (0.05, 0.6) range so the user can't drag the pane to
  /// effective invisibility.
  Future<void> setTestBrowserFraction(double fraction) async {
    await _update(
      state.copyWith(testBrowserFraction: _clamp(fraction)),
    );
  }

  /// Updates the run details pane's width fraction.
  Future<void> setRunDetailsFraction(double fraction) async {
    await _update(
      state.copyWith(runDetailsFraction: _clamp(fraction)),
    );
  }

  /// Updates the bottom log panel's height fraction.
  Future<void> setLogPanelFraction(double fraction) async {
    await _update(
      state.copyWith(logPanelFraction: _clamp(fraction)),
    );
  }

  /// Resets every pane to its default visibility and size.
  Future<void> resetToDefaults() async {
    await _update(const PanelLayoutState());
  }

  double _clamp(double fraction) {
    if (fraction.isNaN) return 0.2;
    if (fraction < 0.05) return 0.05;
    if (fraction > 0.6) return 0.6;
    return fraction;
  }

  Future<void> _update(PanelLayoutState next) async {
    if (next == state) return;
    state = next;
    // Mirror to disk. The notifier's state is the source of truth;
    // settings persistence is a side effect, not a guard.
    final notifier = ref.read(appSettingsProvider.notifier);
    await notifier.updatePanelLayout(next);
  }
}
