// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_settings/crux_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/domain/models/panel_layout_state.dart';
import 'package:simcrux/domain/models/pass_fail_config_codec.dart';
import 'package:simcrux/domain/models/retention_policy.dart';
import 'package:simcrux/services/settings/simcrux_settings_codec.dart';

/// Service instance shared by every consumer of [appSettingsProvider].
///
/// Exposed as its own provider so tests can override it with a
/// [SettingsService] constructed against
/// `SharedPreferences.setMockInitialValues({})` — no need to touch the
/// real platform plugin.
final Provider<SettingsService<AppSettings>> settingsServiceProvider =
    Provider<SettingsService<AppSettings>>(
      (ref) => const SettingsService<AppSettings>(SimcruxSettingsCodec()),
    );

/// Loaded [AppSettings].
///
/// `AsyncNotifierProvider` so the first frame can render against the
/// settings defaults while persistence resolves; once loaded, consumers
/// see the persisted values. Calls to mutators (e.g.
/// [AppSettingsNotifier.addRecentProject]) flush to disk via
/// [SettingsService.save] and update the in-memory state.
final AsyncNotifierProvider<AppSettingsNotifier, AppSettings>
appSettingsProvider = AsyncNotifierProvider<AppSettingsNotifier, AppSettings>(
  AppSettingsNotifier.new,
);

/// Notifier backing [appSettingsProvider].
class AppSettingsNotifier extends AsyncNotifier<AppSettings> {
  @override
  Future<AppSettings> build() async {
    final service = ref.read(settingsServiceProvider);
    return service.load();
  }

  /// Records [path] at the top of the recent-projects list, removing
  /// any previous entry for the same path (case-sensitive). Trims to
  /// [AppSettings.recentProjectsMax].
  Future<void> addRecentProject(String path) async {
    final current = state.value;
    if (current == null) return;
    final next = <String>[path];
    for (final existing in current.recentProjectPaths) {
      if (existing == path) continue;
      next.add(existing);
      if (next.length >= AppSettings.recentProjectsMax) break;
    }
    final updated = current.copyWith(recentProjectPaths: next);
    state = AsyncData(updated);
    await ref.read(settingsServiceProvider).save(updated);
  }

  /// Removes [path] from the recent-projects list, if present.
  Future<void> removeRecentProject(String path) async {
    final current = state.value;
    if (current == null) return;
    final filtered = current.recentProjectPaths
        .where((p) => p != path)
        .toList(growable: false);
    if (filtered.length == current.recentProjectPaths.length) return;
    final updated = current.copyWith(recentProjectPaths: filtered);
    state = AsyncData(updated);
    await ref.read(settingsServiceProvider).save(updated);
  }

  /// Persists a new [PanelLayoutState]. Called by
  /// [PanelLayoutNotifier] whenever the user toggles a pane or
  /// drag-resizes a splitter.
  Future<void> updatePanelLayout(PanelLayoutState layout) async {
    final current = state.value;
    if (current == null) return;
    if (current.panelLayout == layout) return;
    final updated = current.copyWith(panelLayout: layout);
    state = AsyncData(updated);
    await ref.read(settingsServiceProvider).save(updated);
  }

  /// Sets the active color-theme preset id (e.g. `wavecrux-dark`,
  /// `solarized-dark`). Wired through `cruxColorThemeProvider` by the
  /// SimCrux notifier override — the in-memory theme rebuilds from the
  /// persisted name + overrides on the next read.
  Future<void> setActiveThemeName(String name) async {
    final current = state.value;
    if (current == null) return;
    final updated = current.copyWith(
      core: current.core.copyWith(activeThemeName: name),
    );
    state = AsyncData(updated);
    await ref.read(settingsServiceProvider).save(updated);
  }

  /// Replaces the flat token-path override map fed into the
  /// `cruxColorThemeProvider` bridge. Pass an empty map to clear all
  /// overrides.
  Future<void> setThemeOverrides(Map<String, String> overrides) async {
    final current = state.value;
    if (current == null) return;
    final updated = current.copyWith(
      core: current.core.copyWith(
        themeOverrides: Map<String, String>.unmodifiable(overrides),
      ),
    );
    state = AsyncData(updated);
    await ref.read(settingsServiceProvider).save(updated);
  }

  /// Persists the UI language ([CoreSettings.locale]); `app.dart` watches
  /// it and rebuilds `MaterialApp.locale`, so the switch applies live.
  Future<void> setLocale(String locale) async {
    final current = state.value;
    if (current == null) return;
    final updated = current.copyWith(
      core: current.core.copyWith(locale: locale),
    );
    state = AsyncData(updated);
    await ref.read(settingsServiceProvider).save(updated);
  }

  /// Updates the auto-reload mode (lives on CoreSettings).
  Future<void> updateAutoReloadMode(AutoReloadMode mode) async {
    final current = state.value;
    if (current == null) return;
    final updated = current.copyWith(
      core: current.core.copyWith(autoReloadMode: mode),
    );
    state = AsyncData(updated);
    await ref.read(settingsServiceProvider).save(updated);
  }

  /// Toggles the "automatically check for updates" preference.
  ///
  /// Persisted, then read back by `crux_updates`'
  /// `autoUpdateCheckEnabledProvider` (wired in `simcruxUpdateOverrides`), so
  /// disabling it suppresses the launch check, the 24 h periodic check and the
  /// on-resume re-check. The manual `Check for Updates` action is unaffected.
  Future<void> updateAutoCheckForUpdates({required bool enabled}) async {
    final current = state.value;
    if (current == null) return;
    if (current.autoCheckForUpdates == enabled) return;
    final updated = current.copyWith(autoCheckForUpdates: enabled);
    state = AsyncData(updated);
    await ref.read(settingsServiceProvider).save(updated);
  }

  /// Persists the release-build diagnostics opt-in (lives on CoreSettings).
  ///
  /// Read back by `diagnosticsEnabledProvider`, which gates Tools → Tab
  /// Diagnostics in release builds; debug and profile builds ignore it.
  Future<void> updateDiagnosticsEnabled({required bool enabled}) async {
    final current = state.value;
    if (current == null) return;
    if (current.diagnosticsEnabled == enabled) return;
    final updated = current.copyWith(
      core: current.core.copyWith(diagnosticsEnabled: enabled),
    );
    state = AsyncData(updated);
    await ref.read(settingsServiceProvider).save(updated);
  }

  /// Persists whether opening a regression config auto-starts the run.
  Future<void> updateAutoRunOnOpen({required bool enabled}) async {
    final current = state.value;
    if (current == null) return;
    if (current.autoRunOnOpen == enabled) return;
    final updated = current.copyWith(autoRunOnOpen: enabled);
    state = AsyncData(updated);
    await ref.read(settingsServiceProvider).save(updated);
  }

  /// Persists which driver plugins the user has switched off.
  ///
  /// `true` means disabled; an absent id means enabled, so a plugin
  /// installed after the preference was written is on by default.
  Future<void> setPerPluginDisabled(Map<String, bool> disabled) async {
    final current = state.value;
    if (current == null) return;
    final next = Map<String, bool>.unmodifiable(disabled);
    final previous = current.core.perPluginDisabled;
    if (previous.length == next.length &&
        previous.entries.every((e) => next[e.key] == e.value)) {
      return;
    }
    final updated = current.copyWith(
      core: current.core.copyWith(perPluginDisabled: next),
    );
    state = AsyncData(updated);
    await ref.read(settingsServiceProvider).save(updated);
  }

  /// Persists the trend-store + waveform retention policy.
  ///
  /// Named `set` rather than `update` because the policy is replaced whole:
  /// its fields are individually nullable for "no limit", so a partial
  /// merge could not distinguish "leave this alone" from "clear this".
  Future<void> setRetentionPolicy(RetentionPolicy policy) async {
    final current = state.value;
    if (current == null) return;
    if (current.retentionPolicy == policy) return;
    final updated = current.copyWith(retentionPolicy: policy);
    state = AsyncData(updated);
    await ref.read(settingsServiceProvider).save(updated);
  }

  /// Updates the inspector's log-preview tail line count.
  Future<void> updateInspectorLogPreviewLineCount(int count) async {
    final current = state.value;
    if (current == null) return;
    final updated = current.copyWith(inspectorLogPreviewLineCount: count);
    state = AsyncData(updated);
    await ref.read(settingsServiceProvider).save(updated);
  }

  /// Updates the editor shell-out command template.
  Future<void> updateEditorCommandTemplate(String template) async {
    final current = state.value;
    if (current == null) return;
    final updated = current.copyWith(editorCommandTemplate: template);
    state = AsyncData(updated);
    await ref.read(settingsServiceProvider).save(updated);
  }

  /// Updates the per-simulator binary path override map.
  Future<void> updateSimulatorBinaryOverrides(
    Map<String, String> overrides,
  ) async {
    final current = state.value;
    if (current == null) return;
    final updated = current.copyWith(simulatorBinaryOverrides: overrides);
    state = AsyncData(updated);
    await ref.read(settingsServiceProvider).save(updated);
  }

  /// Turns project-defined tooling on or off for this machine.
  ///
  /// See [AppSettings.allowProjectDefinedTooling]: with it on, an
  /// opened `simcrux.yaml` may name the executable SimCrux spawns and
  /// the environment it spawns under. Off by default.
  Future<void> setAllowProjectDefinedTooling({required bool enabled}) async {
    final current = state.value;
    if (current == null) return;
    if (current.allowProjectDefinedTooling == enabled) return;
    final updated = current.copyWith(allowProjectDefinedTooling: enabled);
    state = AsyncData(updated);
    await ref.read(settingsServiceProvider).save(updated);
  }

  /// Inserts or replaces a reusable detector by [name].
  Future<void> putReusableDetector(String name, DetectorSpec spec) async {
    final current = state.value;
    if (current == null) return;
    final next = Map<String, DetectorSpec>.from(current.reusableDetectors)
      ..[name] = spec;
    final updated = current.copyWith(reusableDetectors: next);
    state = AsyncData(updated);
    await ref.read(settingsServiceProvider).save(updated);
  }

  /// Removes the reusable detector named [name]. No-op when absent.
  Future<void> removeReusableDetector(String name) async {
    final current = state.value;
    if (current == null) return;
    if (!current.reusableDetectors.containsKey(name)) return;
    final next = Map<String, DetectorSpec>.from(current.reusableDetectors)
      ..remove(name);
    final updated = current.copyWith(reusableDetectors: next);
    state = AsyncData(updated);
    await ref.read(settingsServiceProvider).save(updated);
  }

  /// Enables or disables the CXP server.
  Future<void> updateCxpServerEnabled({required bool enabled}) async {
    final current = state.value;
    if (current == null) return;
    if (current.cxpServerEnabled == enabled) return;
    final updated = current.copyWith(cxpServerEnabled: enabled);
    state = AsyncData(updated);
    await ref.read(settingsServiceProvider).save(updated);
  }

  /// Updates whether an actionable inbound cross-probe requests the user's
  /// attention (dock bounce / taskbar flash — never a focus steal). The
  /// settings→lifecycle bridge (`cxpAttentionBridgeProvider`) observes this and
  /// swaps the global `windowAttentionRequester` accordingly.
  Future<void> updateRequestAttentionOnCrossProbe({
    required bool enabled,
  }) async {
    final current = state.value;
    if (current == null) return;
    if (current.requestAttentionOnCrossProbe == enabled) return;
    final updated = current.copyWith(requestAttentionOnCrossProbe: enabled);
    state = AsyncData(updated);
    await ref.read(settingsServiceProvider).save(updated);
  }

  /// Updates whether the local selection is auto-broadcast to connected CXP
  /// peers as it changes (live cross-probe). The `notify_selection` emitter
  /// observes this: when false it stops announcing selection changes, so only
  /// explicit sends (e.g. "Debug in WaveCrux") are shared.
  Future<void> updateBroadcastSelectionOnCrossProbe({
    required bool enabled,
  }) async {
    final current = state.value;
    if (current == null) return;
    if (current.broadcastSelectionOnCrossProbe == enabled) return;
    final updated = current.copyWith(broadcastSelectionOnCrossProbe: enabled);
    state = AsyncData(updated);
    await ref.read(settingsServiceProvider).save(updated);
  }

  /// Updates the CXP server's listening port. Values outside the
  /// 1–65535 IANA range are rejected (no state change, no save).
  Future<void> updateCxpServerPort(int port) async {
    final current = state.value;
    if (current == null) return;
    if (port < 1 || port > 65535) return;
    if (current.cxpServerPort == port) return;
    final updated = current.copyWith(cxpServerPort: port);
    state = AsyncData(updated);
    await ref.read(settingsServiceProvider).save(updated);
  }

  /// Records [path] at the top of the recent-sessions list.
  Future<void> addRecentSession(String path) async {
    final current = state.value;
    if (current == null) return;
    final next = <String>[path];
    for (final existing in current.recentSessionPaths) {
      if (existing == path) continue;
      next.add(existing);
      if (next.length >= AppSettings.recentProjectsMax) break;
    }
    final updated = current.copyWith(recentSessionPaths: next);
    state = AsyncData(updated);
    await ref.read(settingsServiceProvider).save(updated);
  }
}
