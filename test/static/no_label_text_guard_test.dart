// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Static guard: no `InputDecoration` in `lib/` names its field with
// `labelText`.
//
// The Crux Desktop theme never floats a label, so a `labelText` shows only
// while the field is empty; a field that holds a value then reads as a bare
// number or string with no name. A field that must be identified sits in a
// `CruxFormRow` (label always visible, the row's label as its accessible
// name); a search or filter box whose purpose stays obvious from its icon and
// placement uses `hintText` plus an explicit `Semantics` label.
//
// Comments are not scanned. There are no allowances: a site that cannot move
// is listed in `_allowed` with the reason, one entry per line, and the list
// never grows.

import 'package:flutter_test/flutter_test.dart';

import 'crux_guard_sources.dart';

/// `file:line` -> why that `labelText:` may stay. Empty on purpose.
const Map<String, String> _allowed = <String, String>{};

final RegExp _labelText = RegExp(r'\blabelText\s*:');

void main() {
  test('no InputDecoration in lib/ uses labelText', () {
    final sources = cruxGuardSourcesUnder('lib');
    expect(
      sources.length,
      greaterThan(100),
      reason: 'the source walk collected implausibly few files',
    );

    final found = <String>[];
    for (final source in sources) {
      final lines = source.source.split('\n');
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;
        if (!_labelText.hasMatch(line)) continue;
        final where = '${source.path}:${i + 1}';
        if (_allowed.containsKey(where)) continue;
        found.add('$where  ${line.trim()}');
      }
    }

    expect(
      found,
      isEmpty,
      reason:
          'labelText vanishes once a field holds a value in the desktop '
          'theme. Use a CruxFormRow (label left, always visible), or for a '
          'search box hintText plus an explicit Semantics label:\n'
          '${found.join('\n')}',
    );
  });

  test('every allowance still points at a labelText line', () {
    final sources = {
      for (final s in cruxGuardSourcesUnder('lib')) s.path: s.source,
    };
    for (final where in _allowed.keys) {
      final parts = where.split(':');
      final text = sources[parts.first];
      expect(text, isNotNull, reason: '$where: file is gone');
      final line = text!.split('\n')[int.parse(parts.last) - 1];
      expect(_labelText.hasMatch(line), isTrue, reason: '$where: stale');
    }
  });
}
