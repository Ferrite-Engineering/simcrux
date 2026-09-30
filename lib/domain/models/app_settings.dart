// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_settings/crux_settings.dart';
import 'package:meta/meta.dart';
import 'package:simcrux/domain/models/panel_layout_state.dart';
import 'package:simcrux/domain/models/pass_fail_config_codec.dart';
import 'package:simcrux/domain/models/retention_policy.dart';

/// Persistent application preferences.
///
/// Immutable value object — update via [copyWith]. Persisted and loaded
/// by `WaveCrux`-style `SettingsService<AppSettings>` (see
/// `lib/services/settings/`) using `shared_preferences` under the
/// `settings.*` and `simcrux.*` key namespaces.
///
/// Composes a [CoreSettings] (cross-suite shared subset — 14 fields)
/// plus the SimCrux-specific fields. Consumers can read either via
/// the flat forwarder getters (`settings.themeMode`) or via the
/// explicit `settings.core.themeMode` traversal. Both work; flat is
/// preferred for brevity.
@immutable
class AppSettings {
  /// Creates an [AppSettings]. Every parameter has a documented default
  /// so `const AppSettings()` returns the SimCrux baseline.
  const AppSettings({
    this.core = const CoreSettings.defaults(),
    this.recentProjectPaths = const <String>[],
    this.recentSessionPaths = const <String>[],
    this.panelLayout = const PanelLayoutState(),
    this.inspectorLogPreviewLineCount = 50,
    this.editorCommandTemplate = 'code --goto {file}:{line}:{column}',
    this.simulatorBinaryOverrides = const <String, String>{},
    this.allowProjectDefinedTooling = false,
    this.simulatorDefaultOptions = const <String, List<String>>{},
    this.reusableDetectors = const <String, DetectorSpec>{},
    this.cxpServerEnabled = true,
    this.cxpServerPort = 54325,
    this.requestAttentionOnCrossProbe = true,
    this.broadcastSelectionOnCrossProbe = true,
    this.autoCheckForUpdates = true,
    this.autoRunOnOpen = false,
    this.retentionPolicy = RetentionPolicy.defaultPolicy,
  });

  /// The cross-suite shared subset of settings (theme, locale,
  /// diagnostics flag, plugin directories, theme overrides,
  /// restore-tabs-on-launch, …). Stored as a sub-object so simcrux
  /// and the rest of the suite share the model.
  final CoreSettings core;

  // ─── simcrux-specific fields ──────────────────────────────────────────

  /// Absolute paths of recently opened `simcrux.yaml` project files,
  /// most-recently-opened first. Capped at [recentProjectsMax] entries.
  /// Surfaced on the Welcome screen and in the future File menu.
  final List<String> recentProjectPaths;

  /// Absolute paths of recently opened `.simcrux-session` files,
  /// most-recently-opened first. Capped at [recentProjectsMax]
  /// entries. Surfaced on the Welcome screen and in the File menu.
  final List<String> recentSessionPaths;

  /// Maximum number of recent project / session paths retained.
  /// Older entries fall off the end as new files are opened.
  static const int recentProjectsMax = 10;

  /// Visibility + size of the four `IdeLayout` panels. Persisted so
  /// the user's layout customizations survive across launches.
  final PanelLayoutState panelLayout;

  /// How many trailing log lines to display in the inspector's
  /// log-preview section. Configurable via Settings → General.
  final int inspectorLogPreviewLineCount;

  /// Shell command used by source-navigation actions. Recognized
  /// placeholders: `{file}`, `{line}`, `{column}`. The first
  /// whitespace-separated token is the executable; remaining tokens
  /// are passed as positional arguments after placeholder
  /// substitution.
  final String editorCommandTemplate;

  /// Per-simulator binary path overrides. Keys are
  /// [SimulatorDriver.id] (e.g. `icarus`, `verilator`); values are
  /// absolute paths (or directory prefixes) the simulator drivers
  /// resolve against [SimulatorBinaryConfig.customPath]. Empty by
  /// default — drivers fall back to `$PATH`.
  final Map<String, String> simulatorBinaryOverrides;

  /// Whether a `simcrux.yaml` opened on this machine may choose which
  /// executable SimCrux spawns and under what environment.
  ///
  /// Gates `simulators.<id>.path`, `simulators.<id>.env`, and the
  /// `riscv.target` / `riscv.riscof` / `riscv.compile` `command:` argv
  /// lists. Every one of them is arbitrary code execution on this
  /// machine, and a project file is untrusted input — `.yaml` / `.yml`
  /// are registered SimCrux document types, so one arrives by
  /// double-click, by `git clone`, or by download, and a user who has
  /// turned on [autoRunOnOpen] never even presses Run.
  ///
  /// Default **false**. With it off the loader drops `path:` / `env:`
  /// with a load advisory and refuses a `command:` outright; the user's
  /// own `Settings → Simulators → Binary path` override
  /// ([simulatorBinaryOverrides]) is unaffected, because that value came
  /// from the user rather than from the file.
  ///
  /// Deliberately coarse — one switch for this machine rather than a
  /// per-project trust record — because no workspace-trust concept
  /// exists anywhere in the suite yet. See `ConfigLoader`.
  final bool allowProjectDefinedTooling;

  /// Per-simulator default extra options. Keys are
  /// [SimulatorDriver.id]; values are extra CLI flags the user wants
  /// prepended to every invocation of that simulator. Empty by
  /// default.
  final Map<String, List<String>> simulatorDefaultOptions;

  /// User-defined reusable pass/fail detector trees, keyed by
  /// human-readable name (e.g. `strict-uvm`). Surfaced in the
  /// Settings → Detectors panel and resolved by the config loader
  /// when a `simcrux.yaml` `pass_fail:` block references one via
  /// `{type: use, name: <name>}`.
  final Map<String, DetectorSpec> reusableDetectors;

  /// Whether the SimCrux CXP server starts at app boot. Default: true.
  ///
  /// CXP is the cross-product peer cross-probe protocol that lets
  /// Crux apps (and third-party tools) gossip selection events,
  /// request highlights, and dispatch the "Debug in WaveCrux" flow.
  /// Distinct from any external driver protocol — peer cross-probe
  /// is bidirectional and symmetric (https://edacrux.app/cxp).
  final bool cxpServerEnabled;

  /// Localhost port the CXP server binds to. Default: 54325 (the
  /// SimCrux slot in the per-product port assignment;
  /// WaveCrux=54322, NetCrux=54323, LintCrux=54324, SimCrux=54325).
  final int cxpServerPort;

  /// Whether an actionable inbound cross-probe requests the user's attention
  /// (a dock bounce / taskbar flash — never a focus steal). Default: true.
  ///
  /// Gated here: the settings→lifecycle bridge
  /// swaps the global `windowAttentionRequester` between the method-channel
  /// backend (on) and a no-op (off), so turning this off makes every inbound
  /// `requestUserAttention()` a silent no-op.
  final bool requestAttentionOnCrossProbe;

  /// Whether SimCrux auto-broadcasts the local selection to connected CXP
  /// peers as it changes (live cross-probe). Default: true.
  ///
  /// Gates the `notify_selection` outbound emitter: when false the emitter
  /// stops announcing selection changes, so only explicit sends (e.g. the
  /// "Debug in WaveCrux" flow) are shared. When true, selecting a test or
  /// navigating to a source file broadcasts a `notify_selection` to every
  /// subscribed peer.
  final bool broadcastSelectionOnCrossProbe;

  /// Whether SimCrux checks the release manifest for a newer version
  /// automatically — once at launch, once per
  /// `CruxUpdateConfig.checkInterval` (24 h), and on app resume.
  /// Default: true.
  ///
  /// Feeds `crux_updates`' `autoUpdateCheckEnabledProvider`, which gates
  /// every *scheduled* check. The manual `Check for Updates` action
  /// ignores this setting entirely — an explicit request always runs.
  /// Turning it off also stops the manifest's `server_time` watermark
  /// from advancing, which is accepted: expiry then falls back to the
  /// device clock, exactly as on a never-online install.
  final bool autoCheckForUpdates;

  /// Whether opening a regression config immediately starts the run.
  ///
  /// **Off by default, by design.** Opening a file must not
  /// launch two hundred tests: it is surprising, and in a real setup it
  /// checks out simulator licences on a misclick. With this off, opening
  /// a config leaves the tab *armed* — config loaded, test browser
  /// populated, watcher watching — and waits for Run Regression.
  ///
  /// It does not affect the auto-reload path: the "Sources changed —
  /// Re-run now?" prompt and `AutoReloadMode.auto` are a separate,
  /// already-explicit opt-in about a run that is already the user's.
  final bool autoRunOnOpen;

  /// Trend-store and waveform retention rules.
  ///
  /// Persisted so the policy survives a restart. It used to live only in
  /// `retentionPolicyProvider`'s in-memory notifier, so a user who dialled
  /// retention down to keep their disk under control got the 30-day /
  /// 50 000-point / 10-waveform defaults back the next time they launched
  /// — and the sweep they had asked for silently stopped happening.
  final RetentionPolicy retentionPolicy;

  // ─── Forwarder getters into [core] ────────────────────────────────────
  // Preserve a flat read API so consumers don't have to traverse
  // .core.x for the common case.

  /// Forwarder for [CoreSettings.themeMode].
  AppThemeMode get themeMode => core.themeMode;

  /// Forwarder for [CoreSettings.locale].
  String get locale => core.locale;

  /// Forwarder for [CoreSettings.diagnosticsEnabled].
  bool get diagnosticsEnabled => core.diagnosticsEnabled;

  /// Forwarder for [CoreSettings.restoreTabsOnLaunch].
  bool get restoreTabsOnLaunch => core.restoreTabsOnLaunch;

  /// Forwarder for [CoreSettings.autoReloadMode].
  AutoReloadMode get autoReloadMode => core.autoReloadMode;

  /// Returns a copy with the given fields replaced.
  AppSettings copyWith({
    CoreSettings? core,
    List<String>? recentProjectPaths,
    List<String>? recentSessionPaths,
    PanelLayoutState? panelLayout,
    int? inspectorLogPreviewLineCount,
    String? editorCommandTemplate,
    Map<String, String>? simulatorBinaryOverrides,
    bool? allowProjectDefinedTooling,
    Map<String, List<String>>? simulatorDefaultOptions,
    Map<String, DetectorSpec>? reusableDetectors,
    bool? cxpServerEnabled,
    int? cxpServerPort,
    bool? requestAttentionOnCrossProbe,
    bool? broadcastSelectionOnCrossProbe,
    bool? autoCheckForUpdates,
    bool? autoRunOnOpen,
    RetentionPolicy? retentionPolicy,
  }) {
    return AppSettings(
      core: core ?? this.core,
      recentProjectPaths: recentProjectPaths ?? this.recentProjectPaths,
      recentSessionPaths: recentSessionPaths ?? this.recentSessionPaths,
      panelLayout: panelLayout ?? this.panelLayout,
      inspectorLogPreviewLineCount:
          inspectorLogPreviewLineCount ?? this.inspectorLogPreviewLineCount,
      editorCommandTemplate:
          editorCommandTemplate ?? this.editorCommandTemplate,
      simulatorBinaryOverrides:
          simulatorBinaryOverrides ?? this.simulatorBinaryOverrides,
      allowProjectDefinedTooling:
          allowProjectDefinedTooling ?? this.allowProjectDefinedTooling,
      simulatorDefaultOptions:
          simulatorDefaultOptions ?? this.simulatorDefaultOptions,
      reusableDetectors: reusableDetectors ?? this.reusableDetectors,
      cxpServerEnabled: cxpServerEnabled ?? this.cxpServerEnabled,
      cxpServerPort: cxpServerPort ?? this.cxpServerPort,
      requestAttentionOnCrossProbe:
          requestAttentionOnCrossProbe ?? this.requestAttentionOnCrossProbe,
      broadcastSelectionOnCrossProbe:
          broadcastSelectionOnCrossProbe ?? this.broadcastSelectionOnCrossProbe,
      autoCheckForUpdates: autoCheckForUpdates ?? this.autoCheckForUpdates,
      autoRunOnOpen: autoRunOnOpen ?? this.autoRunOnOpen,
      retentionPolicy: retentionPolicy ?? this.retentionPolicy,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! AppSettings) return false;
    if (core != other.core) return false;
    if (panelLayout != other.panelLayout) return false;
    if (inspectorLogPreviewLineCount != other.inspectorLogPreviewLineCount) {
      return false;
    }
    if (editorCommandTemplate != other.editorCommandTemplate) return false;
    if (!_listEquals(recentProjectPaths, other.recentProjectPaths)) {
      return false;
    }
    if (!_listEquals(recentSessionPaths, other.recentSessionPaths)) {
      return false;
    }
    if (!_mapEquals(simulatorBinaryOverrides, other.simulatorBinaryOverrides)) {
      return false;
    }
    if (allowProjectDefinedTooling != other.allowProjectDefinedTooling) {
      return false;
    }
    if (simulatorDefaultOptions.length !=
        other.simulatorDefaultOptions.length) {
      return false;
    }
    for (final entry in simulatorDefaultOptions.entries) {
      final otherList = other.simulatorDefaultOptions[entry.key];
      if (otherList == null) return false;
      if (!_listEquals(entry.value, otherList)) return false;
    }
    if (reusableDetectors.length != other.reusableDetectors.length) {
      return false;
    }
    for (final entry in reusableDetectors.entries) {
      if (other.reusableDetectors[entry.key] != entry.value) return false;
    }
    if (cxpServerEnabled != other.cxpServerEnabled) return false;
    if (cxpServerPort != other.cxpServerPort) return false;
    if (requestAttentionOnCrossProbe != other.requestAttentionOnCrossProbe) {
      return false;
    }
    if (broadcastSelectionOnCrossProbe !=
        other.broadcastSelectionOnCrossProbe) {
      return false;
    }
    if (autoCheckForUpdates != other.autoCheckForUpdates) return false;
    if (autoRunOnOpen != other.autoRunOnOpen) return false;
    if (retentionPolicy != other.retentionPolicy) return false;
    return true;
  }

  @override
  int get hashCode => Object.hash(
    core,
    Object.hashAll(recentProjectPaths),
    Object.hashAll(recentSessionPaths),
    panelLayout,
    inspectorLogPreviewLineCount,
    editorCommandTemplate,
    Object.hashAllUnordered(
      simulatorBinaryOverrides.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    allowProjectDefinedTooling,
    Object.hashAllUnordered(
      simulatorDefaultOptions.entries.map(
        (e) => Object.hash(e.key, Object.hashAll(e.value)),
      ),
    ),
    Object.hashAllUnordered(
      reusableDetectors.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    cxpServerEnabled,
    cxpServerPort,
    requestAttentionOnCrossProbe,
    broadcastSelectionOnCrossProbe,
    autoCheckForUpdates,
    autoRunOnOpen,
    retentionPolicy,
  );

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _mapEquals(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }
}
