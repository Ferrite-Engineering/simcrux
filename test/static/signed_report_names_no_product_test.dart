// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// The signed coverage report's open-core half (the View menu entry, its
// palette entry, the opener seam and the catalogue events) names no product
// that writes the report. The label is "Signed Coverage Report…", and every
// string that names the tool behind a report lives in the Pro overlay's own
// ARB files. This guard holds the whole open core to that: no ARB message and
// no source, test, asset or document file carries the name.
//
// The name is assembled from two halves so this file does not carry it
// either.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final RegExp _name = RegExp(<String>['ferro', r'[\s_-]?', 'proof'].join());

const List<String> _roots = <String>[
  'lib',
  'test',
  'assets',
  'docs',
  'tool',
  'spec',
  'bin',
];

const Set<String> _textExtensions = <String>{
  '.dart',
  '.arb',
  '.json',
  '.md',
  '.yaml',
  '.yml',
  '.txt',
  '.sh',
  '.py',
};

bool _isText(String path) =>
    _textExtensions.any((ext) => path.toLowerCase().endsWith(ext));

void main() {
  test('no open-core ARB message names the report tool', () {
    final arbs = Directory('lib/l10n')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.arb'))
        .toList();
    expect(arbs, hasLength(greaterThanOrEqualTo(5)));
    final offenders = <String>[
      for (final arb in arbs)
        for (final MapEntry(:key, :value)
            in (jsonDecode(arb.readAsStringSync()) as Map<String, dynamic>)
                .entries)
          if (value is String && _name.hasMatch(value.toLowerCase()))
            '${arb.path} $key',
    ];
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('the View menu label is "Signed Coverage Report…" in English', () {
    final en =
        jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
            as Map<String, dynamic>;
    expect(en['actionOpenSignedReport'], 'Signed Coverage Report…');
  });

  test('no open-core file names the report tool', () {
    final offenders = <String>[];
    var scanned = 0;
    for (final root in _roots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is! File || !_isText(entity.path)) continue;
        if (p.split(entity.path).contains('generated')) continue;
        scanned++;
        final String text;
        try {
          text = entity.readAsStringSync();
        } on Exception {
          // Not UTF-8 text, or unreadable: not a file this guard reads.
          continue;
        }
        if (_name.hasMatch(text.toLowerCase())) offenders.add(entity.path);
      }
    }
    expect(scanned, greaterThan(500), reason: 'the walk found too few files');
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });
}
