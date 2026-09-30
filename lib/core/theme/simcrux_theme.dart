// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:simcrux/core/theme/simcrux_colors.dart';

/// Builders for the SimCrux Material 3 themes.
///
/// Both light and dark themes are derived from a single brand seed
/// ([SimcruxColors.brandSeed], a muted indigo). Dark is the default —
/// engineers stare at regression dashboards for hours, and dark chrome
/// is the engineering-tool convention. Mirrors the NetCrux and WaveCrux
/// theme builders.
abstract final class SimcruxTheme {
  /// Light Material 3 theme.
  static ThemeData light() => _build(Brightness.light);

  /// Dark Material 3 theme — the SimCrux default.
  static ThemeData dark() => _build(Brightness.dark);

  /// High-contrast light theme, used when the platform reports the
  /// high-contrast accessibility setting is on. Wired into
  /// [MaterialApp.highContrastTheme]; mirrors WaveCrux's accessibility
  /// parity.
  static ThemeData highContrastLight() =>
      _build(Brightness.light, highContrast: true);

  /// High-contrast dark theme, used when the platform reports the
  /// high-contrast accessibility setting is on. Wired into
  /// [MaterialApp.highContrastDarkTheme].
  static ThemeData highContrastDark() =>
      _build(Brightness.dark, highContrast: true);

  static ThemeData _build(Brightness brightness, {bool highContrast = false}) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: SimcruxColors.brandSeed,
      brightness: brightness,
      // Material 3 raises the tonal separation between roles as the
      // contrast level climbs; 1.0 is the maximum and is what the
      // high-contrast accessibility themes want.
      contrastLevel: highContrast ? 1 : 0,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: brightness == Brightness.dark
          ? SimcruxColors.darkCanvasBackground
          : SimcruxColors.lightCanvasBackground,
      visualDensity: VisualDensity.adaptivePlatformDensity,
    );
  }
}
