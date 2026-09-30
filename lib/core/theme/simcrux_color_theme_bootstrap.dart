// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_theme/crux_theme.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' show Color;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:logging/logging.dart';
import 'package:simcrux/core/theme/theme_pack_directory.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';

/// A theme pack the user chose and did not get back. `developer.log` emits
/// nothing from a release build, so this goes to the product log.
final _log = Logger('simcrux.theme');

/// Riverpod override that wires SimCrux persistence into `crux_theme`'s
/// `cruxColorThemeProvider`. Mirrors the WaveCrux / NetCrux reference
/// notifiers so the suite presents a uniform theming surface across all
/// four apps — preset selection writes to
/// `AppSettings.core.activeThemeName` / `core.themeOverrides`, and the
/// in-memory theme rebuilds from those settings whenever the app boots.
class SimcruxCruxColorThemeNotifier extends CruxColorThemeNotifier {
  /// Creates a notifier seeded with the suite-default Crux Dark built-in
  /// preset so reads that race the first settings hydration still
  /// observe a sensible theme.
  SimcruxCruxColorThemeNotifier() : super(initial: defaultBuiltinPreset());

  /// The theme pack in force when the active theme is not a built-in
  /// preset: one activated from Settings → Appearance → Theme packs, or
  /// restored at launch by [restoreActiveThemePack].
  ///
  /// Settings persist only the active theme's id, and [build] re-runs on
  /// every settings change, the activation's own write included. A pack's
  /// tokens are nowhere in settings, so without this the rebuild after
  /// activating a pack found no preset with its id and fell back to the
  /// seed preset at once.
  CruxColorTheme? _packTheme;

  @override
  CruxColorTheme build() {
    final settings = ref.watch(appSettingsProvider).value;
    if (settings == null) return _packTheme ?? initial;
    // `builtinPresetById` (not a raw `presets[...]` lookup) applies the
    // legacy alias map, so a beta user whose settings still persist the
    // retired `wavecrux-dark` / `wavecrux-light` ids keeps their theme
    // instead of silently falling back to the default.
    final id = settings.core.activeThemeName;
    final pack = _packTheme;
    final base =
        builtinPresetById(id) ?? (pack?.id == id ? pack : null) ?? initial;
    if (settings.core.themeOverrides.isEmpty) return base;
    final parsed = _parseOverrides(settings.core.themeOverrides);
    if (parsed.isEmpty) return base;
    return base.mergeTokens(parsed);
  }

  @override
  void activate(CruxColorTheme theme) {
    if (builtinPresetById(theme.id) == null) _packTheme = theme;
    super.activate(theme);
    _persistDerivedFromTheme(theme);
  }

  /// Puts back the theme pack [theme] that settings name as active, at
  /// startup, before the first frame.
  ///
  /// Settings already hold its id, so nothing is written.
  void restorePack(CruxColorTheme theme) {
    _packTheme = theme;
    super.activate(theme);
  }

  @override
  void applyOverrides(Map<String, Color> overrides) {
    if (overrides.isEmpty) return;
    super.applyOverrides(overrides);
    // A pack's edited tokens are its baseline for this session: no
    // override is derived against a pack (see _persistDerivedFromTheme).
    if (_packTheme?.id == state.id) _packTheme = state;
    _persistDerivedFromTheme(state);
  }

  void _persistDerivedFromTheme(CruxColorTheme theme) {
    final baseline = builtinPresetById(theme.id);

    final overrides = <String, String>{};
    if (baseline != null) {
      for (final categoryEntry in theme.tokens.entries) {
        final baselineCategory =
            baseline.tokens[categoryEntry.key] ?? const <String, Color>{};
        for (final tokenEntry in categoryEntry.value.entries) {
          final baselineValue = baselineCategory[tokenEntry.key];
          if (baselineValue == null ||
              baselineValue.toARGB32() != tokenEntry.value.toARGB32()) {
            final dotted = CruxColorTheme.dottedId(
              categoryEntry.key,
              tokenEntry.key,
            );
            overrides[dotted] = ThemePackCodec.encodeColor(tokenEntry.value);
          }
        }
      }
    }

    final notifier = ref.read(appSettingsProvider.notifier);
    // Fire-and-forget: the in-memory state already reflects the new
    // theme; on-disk writes are best-effort and any error surfaces
    // via the SettingsService.
    unawaited(notifier.setActiveThemeName(theme.id));
    unawaited(notifier.setThemeOverrides(overrides));
  }

  static Map<String, Color> _parseOverrides(Map<String, String> raw) {
    final out = <String, Color>{};
    for (final entry in raw.entries) {
      final color = ThemePackCodec.tryParseColor(entry.value);
      if (color != null) out[entry.key] = color;
    }
    return out;
  }
}

/// Re-activates the installed theme pack the saved settings name as active.
///
/// A built-in preset needs nothing: the theme notifier resolves it from
/// settings. A pack's tokens live in its file, so it is loaded here, at
/// bootstrap and before the first frame, instead of the app opening on the
/// default theme. A pack that has since been uninstalled or will not parse
/// is logged and leaves the default theme in place.
///
/// Does nothing on the web, which has no pack directory. [storeResolver]
/// replaces the installed-pack directory in tests.
Future<void> restoreActiveThemePack(
  ProviderContainer container, {
  Future<ThemePackStore> Function()? storeResolver,
}) async {
  if (kIsWeb) return;
  final String id;
  try {
    id = (await container.read(
      appSettingsProvider.future,
    )).core.activeThemeName;
  } on Object {
    return;
  }
  if (builtinPresetById(id) != null) return;

  final notifier = container.read(cruxColorThemeProvider.notifier);
  if (notifier is! SimcruxCruxColorThemeNotifier) return;
  try {
    final store = await (storeResolver ?? _directoryThemePackStore)();
    final pack = await store.loadPack(id);
    notifier.restorePack(pack.toTheme());
  } on Object catch (error) {
    _log.warning('active theme pack "$id" not restored: $error');
  }
}

Future<ThemePackStore> _directoryThemePackStore() async =>
    DirectoryThemePackStore(directory: await simcruxThemePackDirectory());

/// The single override every SimCrux bootstrap spreads into its
/// [ProviderScope] before `runApp`.
final Override simcruxCruxColorThemeOverride = cruxColorThemeProvider
    .overrideWith(SimcruxCruxColorThemeNotifier.new);
