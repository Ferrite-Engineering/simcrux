// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Every user-visible string must be something a screen reader can speak.
//
// Desktop speech engines read arrows, box-drawing characters and private-use
// glyphs as a question mark or skip them. An external NVDA pass heard the
// Settings description "Diagnostics → Logs" as "Diagnostics ? Logs". A menu
// path is written "Settings > AI" (or in words); a mapping is written in
// words ("LSB to slot0"). The same character class is what the focus walk's
// `unspeakableGlyph` rule rejects at run time; this guard catches the string
// before any widget renders it, in every locale.
//
// Keys starting with `@` are translator metadata and are not shown to users.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final RegExp _unspeakable = RegExp(
  '[←-⇿─-◿⟰-⟿⤀-⥿-]',
);

void main() {
  final arbs = Directory(
    'lib/l10n',
  ).listSync().whereType<File>().where((f) => f.path.endsWith('.arb')).toList();

  test('the ARB files were found', () {
    expect(arbs, isNotEmpty);
  });

  for (final arb in arbs) {
    test('${arb.uri.pathSegments.last} has no unspeakable glyphs', () {
      final data = jsonDecode(arb.readAsStringSync()) as Map<String, dynamic>;
      final offenders = <String>[
        for (final entry in data.entries)
          if (!entry.key.startsWith('@') &&
              entry.value is String &&
              _unspeakable.hasMatch(entry.value as String))
            '${entry.key}: ${entry.value}',
      ];
      expect(
        offenders,
        isEmpty,
        reason:
            'These strings contain glyphs a screen reader reads as "?". '
            'Write menu paths as "A > B" and mappings in words.',
      );
    });
  }
}
