// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/theme/simcrux_colors.dart';
import 'package:simcrux/core/theme/simcrux_theme.dart';

void main() {
  group('SimcruxTheme', () {
    test('dark theme uses Material 3 with dark brightness', () {
      final theme = SimcruxTheme.dark();
      expect(theme.useMaterial3, isTrue);
      expect(theme.brightness, Brightness.dark);
    });

    test('light theme uses Material 3 with light brightness', () {
      final theme = SimcruxTheme.light();
      expect(theme.useMaterial3, isTrue);
      expect(theme.brightness, Brightness.light);
    });

    test('dark theme scaffold background uses the dark canvas color', () {
      final theme = SimcruxTheme.dark();
      expect(theme.scaffoldBackgroundColor, SimcruxColors.darkCanvasBackground);
    });

    test('light theme scaffold background uses the light canvas color', () {
      final theme = SimcruxTheme.light();
      expect(
        theme.scaffoldBackgroundColor,
        SimcruxColors.lightCanvasBackground,
      );
    });

    test('color scheme is derived from the SimCrux brand seed', () {
      final dark = SimcruxTheme.dark();
      final light = SimcruxTheme.light();
      // ColorScheme.fromSeed() produces different primary tones for each
      // brightness but both must derive from the same seed — verify the
      // brand seed value used by the builder is stable.
      expect(SimcruxColors.brandSeed, const Color(0xFF5C6BC0));
      expect(dark.colorScheme, isNotNull);
      expect(light.colorScheme, isNotNull);
    });

    test('high-contrast themes carry the requested brightness', () {
      expect(SimcruxTheme.highContrastLight().brightness, Brightness.light);
      expect(SimcruxTheme.highContrastDark().brightness, Brightness.dark);
      expect(SimcruxTheme.highContrastLight().useMaterial3, isTrue);
      expect(SimcruxTheme.highContrastDark().useMaterial3, isTrue);
    });

    test('high-contrast schemes differ from the standard schemes', () {
      // The high-contrast builders raise the Material 3 contrastLevel, so
      // the derived scheme must not be byte-identical to the standard one —
      // otherwise the accessibility themes would be dead passthroughs.
      expect(
        SimcruxTheme.highContrastLight().colorScheme,
        isNot(SimcruxTheme.light().colorScheme),
      );
      expect(
        SimcruxTheme.highContrastDark().colorScheme,
        isNot(SimcruxTheme.dark().colorScheme),
      );
    });

    test('high-contrast themes keep the SimCrux canvas backgrounds', () {
      expect(
        SimcruxTheme.highContrastDark().scaffoldBackgroundColor,
        SimcruxColors.darkCanvasBackground,
      );
      expect(
        SimcruxTheme.highContrastLight().scaffoldBackgroundColor,
        SimcruxColors.lightCanvasBackground,
      );
    });
  });

  group('SimcruxColors', () {
    test('status colors follow the universal CI convention', () {
      // These values are intentionally NOT derived from the brand seed —
      // engineers expect a fixed green/red/amber/blue/gray palette.
      expect(SimcruxColors.statusPass, const Color(0xFF2E7D32));
      expect(SimcruxColors.statusFail, const Color(0xFFC62828));
      expect(SimcruxColors.statusVacuous, const Color(0xFFEF6C00));
      expect(SimcruxColors.statusCover, const Color(0xFF1976D2));
      expect(SimcruxColors.statusSkipped, const Color(0xFF9E9E9E));
    });
  });
}
