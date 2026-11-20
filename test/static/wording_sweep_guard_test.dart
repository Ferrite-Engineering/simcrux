// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Wording canon for the labels the 2026-11 suite audit found worded
// differently across the four products (D51, D52). "Cross-Probe Selection…" is
// hyphenated and capitalised like the other Title Case cross-probe labels, and
// "license" is the spelling in every English string.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _locales = ['en', 'zh_CN', 'zh', 'ja', 'ko'];

Map<String, dynamic> _load(String locale) {
  final file = File('lib/l10n/app_$locale.arb');
  if (!file.existsSync()) {
    throw StateError('missing ${file.path}');
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  final arbs = {for (final l in _locales) l: _load(l)};
  final en = arbs['en']!;

  for (final locale in _locales) {
    test('$locale: Cross-Probe Selection ends in an ellipsis', () {
      expect(
        (arbs[locale]!['actionCrossProbeSelection'] as String).endsWith('…'),
        isTrue,
      );
    });
  }

  test('en: Cross-Probe Selection… is hyphenated and capitalised', () {
    expect(en['actionCrossProbeSelection'], 'Cross-Probe Selection…');
  });

  test('en: the not-available notice names the build', () {
    expect(
      en['snackActionUnavailableInThisBuild'],
      '{action} is not available in this build.',
    );
  });

  test('en: no user-visible string spells "licence"', () {
    final offenders = <String>[
      for (final e in en.entries)
        if (!e.key.startsWith('@') &&
            e.value is String &&
            (e.value as String).toLowerCase().contains('licence'))
          e.key,
    ];
    expect(offenders, isEmpty);
  });
}
