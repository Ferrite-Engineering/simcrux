// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:crux_settings/crux_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/domain/models/panel_layout_state.dart';
import 'package:simcrux/domain/models/pass_fail_config_codec.dart';
import 'package:simcrux/domain/models/retention_policy.dart';

/// Concrete codec for [AppSettings] using `SharedPreferences`.
///
/// Delegates the [CoreSettings] portion to [CoreSettingsCodec] (which
/// owns the `settings.*` key namespace shared by every Crux product)
/// and adds SimCrux-specific fields under the `simcrux.*` namespace.
///
/// Forward-compatibility: unknown keys are silently ignored; malformed
/// values fall back to defaults. Old preferences never crash a new
/// build.
class SimcruxSettingsCodec implements SettingsCodec<AppSettings> {
  /// Const constructor — codec is stateless.
  const SimcruxSettingsCodec();

  static const String _kRecentProjectPaths = 'simcrux.recentProjectPaths';
  static const String _kRecentSessionPaths = 'simcrux.recentSessionPaths';
  static const String _kInspectorLogPreviewLineCount =
      'simcrux.inspectorLogPreviewLineCount';
  static const String _kEditorCommandTemplate = 'simcrux.editorCommandTemplate';
  static const String _kSimulatorBinaryOverrides =
      'simcrux.simulatorBinaryOverrides';
  static const String _kAllowProjectDefinedTooling =
      'simcrux.allowProjectDefinedTooling';
  static const String _kSimulatorDefaultOptions =
      'simcrux.simulatorDefaultOptions';
  static const String _kReusableDetectors = 'simcrux.reusableDetectors';
  static const String _kCxpServerEnabled = 'simcrux.cxpServerEnabled';
  static const String _kCxpServerPort = 'simcrux.cxpServerPort';
  static const String _kRequestAttentionOnCrossProbe =
      'simcrux.requestAttentionOnCrossProbe';
  static const String _kBroadcastSelectionOnCrossProbe =
      'simcrux.broadcastSelectionOnCrossProbe';
  static const String _kAutoCheckForUpdates = 'simcrux.autoCheckForUpdates';
  static const String _kAutoRunOnOpen = 'simcrux.autoRunOnOpen';
  static const String _kRetentionPolicy = 'simcrux.retentionPolicy';

  // Panel-layout namespace. Per-field keys (rather than a single JSON
  // blob) so future fields are forward-compatible — an old build that
  // doesn't know `simcrux.panel.fooFraction` simply ignores it.
  static const String _kPanelTestBrowserVisible =
      'simcrux.panel.testBrowserVisible';
  static const String _kPanelRunDetailsVisible =
      'simcrux.panel.runDetailsVisible';
  static const String _kPanelLogPanelVisible = 'simcrux.panel.logPanelVisible';
  static const String _kPanelTestBrowserFraction =
      'simcrux.panel.testBrowserFraction';
  static const String _kPanelRunDetailsFraction =
      'simcrux.panel.runDetailsFraction';
  static const String _kPanelLogPanelFraction =
      'simcrux.panel.logPanelFraction';

  static const CoreSettingsCodec _coreCodec = CoreSettingsCodec();

  @override
  Future<AppSettings> load(SharedPreferences prefs) async {
    final core = await _coreCodec.load(prefs);
    return AppSettings(
      core: core,
      recentProjectPaths: _readStringList(prefs, _kRecentProjectPaths),
      recentSessionPaths: _readStringList(prefs, _kRecentSessionPaths),
      panelLayout: _readPanelLayout(prefs),
      inspectorLogPreviewLineCount:
          prefs.getInt(_kInspectorLogPreviewLineCount) ?? 50,
      editorCommandTemplate:
          prefs.getString(_kEditorCommandTemplate) ??
          'code --goto {file}:{line}:{column}',
      simulatorBinaryOverrides: _readStringMap(
        prefs,
        _kSimulatorBinaryOverrides,
      ),
      // Absent means off. A project file may not choose which binary
      // SimCrux spawns, or its environment, until the user says so —
      // see `AppSettings.allowProjectDefinedTooling`.
      allowProjectDefinedTooling:
          prefs.getBool(_kAllowProjectDefinedTooling) ?? false,
      simulatorDefaultOptions: _readStringListMap(
        prefs,
        _kSimulatorDefaultOptions,
      ),
      reusableDetectors: _readReusableDetectors(prefs),
      retentionPolicy: _readRetentionPolicy(prefs),
      cxpServerEnabled: prefs.getBool(_kCxpServerEnabled) ?? true,
      cxpServerPort: _readClampedPort(prefs, _kCxpServerPort) ?? 54325,
      requestAttentionOnCrossProbe:
          prefs.getBool(_kRequestAttentionOnCrossProbe) ?? true,
      broadcastSelectionOnCrossProbe:
          prefs.getBool(_kBroadcastSelectionOnCrossProbe) ?? true,
      autoCheckForUpdates: prefs.getBool(_kAutoCheckForUpdates) ?? true,
      // Absent means off. Opening a config must not start a run for a
      // user who never asked for it, including on first launch.
      autoRunOnOpen: prefs.getBool(_kAutoRunOnOpen) ?? false,
    );
  }

  /// Reads a port number and clamps it to a valid IANA range. Returns
  /// null when the key is absent or the value is out of range so the
  /// caller can fall back to the default.
  int? _readClampedPort(SharedPreferences prefs, String key) {
    final raw = prefs.getInt(key);
    if (raw == null) return null;
    if (raw < 1 || raw > 65535) return null;
    return raw;
  }

  Map<String, DetectorSpec> _readReusableDetectors(SharedPreferences prefs) {
    final raw = prefs.getString(_kReusableDetectors);
    if (raw == null || raw.isEmpty) return const <String, DetectorSpec>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const <String, DetectorSpec>{};
      final out = <String, DetectorSpec>{};
      decoded.forEach((k, v) {
        if (k is! String || k.isEmpty) return;
        final spec = DetectorSpec.decode(v);
        if (spec != null) out[k] = spec;
      });
      return Map<String, DetectorSpec>.unmodifiable(out);
    } on FormatException {
      return const <String, DetectorSpec>{};
    }
  }

  /// Reads the persisted retention policy, falling back to the built-in
  /// default. A corrupt or hand-edited value falls back too rather than
  /// throwing: an unparseable preference must not stop the app from
  /// starting, and the default is a safe policy rather than an absent one.
  RetentionPolicy _readRetentionPolicy(SharedPreferences prefs) {
    final raw = prefs.getString(_kRetentionPolicy);
    if (raw == null || raw.isEmpty) return RetentionPolicy.defaultPolicy;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) {
        return RetentionPolicy.defaultPolicy;
      }
      return RetentionPolicy.fromJson(decoded);
    } on Object {
      return RetentionPolicy.defaultPolicy;
    }
  }

  @override
  Future<void> save(SharedPreferences prefs, AppSettings settings) async {
    await _coreCodec.save(prefs, settings.core);
    await prefs.setString(
      _kRecentProjectPaths,
      jsonEncode(settings.recentProjectPaths),
    );
    await prefs.setString(
      _kRecentSessionPaths,
      jsonEncode(settings.recentSessionPaths),
    );
    await prefs.setInt(
      _kInspectorLogPreviewLineCount,
      settings.inspectorLogPreviewLineCount,
    );
    await prefs.setString(
      _kEditorCommandTemplate,
      settings.editorCommandTemplate,
    );
    await prefs.setString(
      _kSimulatorBinaryOverrides,
      jsonEncode(settings.simulatorBinaryOverrides),
    );
    await prefs.setBool(
      _kAllowProjectDefinedTooling,
      settings.allowProjectDefinedTooling,
    );
    await prefs.setString(
      _kSimulatorDefaultOptions,
      jsonEncode(settings.simulatorDefaultOptions),
    );
    await prefs.setString(
      _kReusableDetectors,
      jsonEncode(<String, Object?>{
        for (final entry in settings.reusableDetectors.entries)
          entry.key: DetectorSpec.encode(entry.value),
      }),
    );
    await prefs.setBool(_kCxpServerEnabled, settings.cxpServerEnabled);
    await prefs.setInt(_kCxpServerPort, settings.cxpServerPort);
    await prefs.setBool(
      _kRequestAttentionOnCrossProbe,
      settings.requestAttentionOnCrossProbe,
    );
    await prefs.setBool(
      _kBroadcastSelectionOnCrossProbe,
      settings.broadcastSelectionOnCrossProbe,
    );
    await prefs.setBool(_kAutoCheckForUpdates, settings.autoCheckForUpdates);
    await prefs.setBool(_kAutoRunOnOpen, settings.autoRunOnOpen);
    await prefs.setString(
      _kRetentionPolicy,
      jsonEncode(settings.retentionPolicy.toJson()),
    );
    await _writePanelLayout(prefs, settings.panelLayout);
  }

  List<String> _readStringList(SharedPreferences prefs, String key) {
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return const <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <String>[];
      return decoded.whereType<String>().toList(growable: false);
    } on FormatException {
      return const <String>[];
    }
  }

  Map<String, String> _readStringMap(SharedPreferences prefs, String key) {
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return const <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const <String, String>{};
      final out = <String, String>{};
      decoded.forEach((k, v) {
        if (k is String && v is String) out[k] = v;
      });
      return Map<String, String>.unmodifiable(out);
    } on FormatException {
      return const <String, String>{};
    }
  }

  Map<String, List<String>> _readStringListMap(
    SharedPreferences prefs,
    String key,
  ) {
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return const <String, List<String>>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const <String, List<String>>{};
      final out = <String, List<String>>{};
      decoded.forEach((k, v) {
        if (k is String && v is List) {
          out[k] = v.whereType<String>().toList(growable: false);
        }
      });
      return Map<String, List<String>>.unmodifiable(out);
    } on FormatException {
      return const <String, List<String>>{};
    }
  }

  PanelLayoutState _readPanelLayout(SharedPreferences prefs) {
    const defaults = PanelLayoutState();
    return PanelLayoutState(
      testBrowserVisible:
          prefs.getBool(_kPanelTestBrowserVisible) ??
          defaults.testBrowserVisible,
      runDetailsVisible:
          prefs.getBool(_kPanelRunDetailsVisible) ?? defaults.runDetailsVisible,
      logPanelVisible:
          prefs.getBool(_kPanelLogPanelVisible) ?? defaults.logPanelVisible,
      testBrowserFraction:
          _readClampedFraction(prefs, _kPanelTestBrowserFraction) ??
          defaults.testBrowserFraction,
      runDetailsFraction:
          _readClampedFraction(prefs, _kPanelRunDetailsFraction) ??
          defaults.runDetailsFraction,
      logPanelFraction:
          _readClampedFraction(prefs, _kPanelLogPanelFraction) ??
          defaults.logPanelFraction,
    );
  }

  /// Reads a fraction stored as a double and clamps it to (0, 1).
  /// Returns null when the key is absent so the caller can fall back
  /// to the default.
  double? _readClampedFraction(SharedPreferences prefs, String key) {
    final raw = prefs.getDouble(key);
    if (raw == null) return null;
    if (raw <= 0 || raw >= 1 || raw.isNaN) return null;
    return raw;
  }

  Future<void> _writePanelLayout(
    SharedPreferences prefs,
    PanelLayoutState layout,
  ) async {
    await prefs.setBool(_kPanelTestBrowserVisible, layout.testBrowserVisible);
    await prefs.setBool(_kPanelRunDetailsVisible, layout.runDetailsVisible);
    await prefs.setBool(_kPanelLogPanelVisible, layout.logPanelVisible);
    await prefs.setDouble(
      _kPanelTestBrowserFraction,
      layout.testBrowserFraction,
    );
    await prefs.setDouble(
      _kPanelRunDetailsFraction,
      layout.runDetailsFraction,
    );
    await prefs.setDouble(_kPanelLogPanelFraction, layout.logPanelFraction);
  }
}
