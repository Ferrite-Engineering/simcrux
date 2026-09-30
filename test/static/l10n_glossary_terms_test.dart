// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Glossary guard: the shipped translations use the renderings in
// assets/l10n/glossary.json.
//
// The house-style guard checks the shape of the ARB files (key parity, the zh
// mirror, plurals, punctuation) but never read the glossary, so off-glossary
// terms shipped unnoticed: シミュレータ for シミュレーター, 設定ファイル for the
// config (構成), 模拟器 for 仿真器, 리그레션 for 회귀. This guard ties each
// known wrong rendering to the glossary entry it contradicts, checks that the
// glossary itself still says what the rule assumes, and scans every message.
//
// It also holds glossary.json's suite-wide terms to the suite-wide table in
// .claude/instructions.md, which is where the glossary is written first.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _glossaryPath = 'assets/l10n/glossary.json';
const String _instructionsPath = '.claude/instructions.md';

/// ARB files per glossary locale. Both Chinese files carry Simplified text.
const Map<String, List<String>> _arbFilesByLocale = <String, List<String>>{
  'zh': <String>['lib/l10n/app_zh_CN.arb', 'lib/l10n/app_zh.arb'],
  'ja': <String>['lib/l10n/app_ja.arb'],
  'ko': <String>['lib/l10n/app_ko.arb'],
};

/// A rendering the glossary rules out, tied to the entry it contradicts.
class _Forbidden {
  const _Forbidden(this.section, this.term, this.locale, this.pattern);

  /// `terms` or `suite_wide_terms`.
  final String section;

  /// The glossary entry id.
  final String term;

  /// `zh`, `ja` or `ko`.
  final String locale;

  /// What must not appear in any message of that locale.
  final String pattern;

  RegExp get regExp => RegExp(pattern);
}

const List<_Forbidden> _forbidden = <_Forbidden>[
  // Long-vowel form for -er/-or loanwords.
  _Forbidden('terms', 'simulator', 'ja', 'シミュレータ(?!ー)'),
  _Forbidden('terms', 'simulator', 'zh', '模拟器'),
  // 設定 is reserved for the Settings screen; the project config is 構成.
  _Forbidden('terms', 'config_file', 'ja', '設定ファイル'),
  _Forbidden('terms', 'regression', 'ko', '리그레션'),
  _Forbidden('suite_wide_terms', 'custom', 'ko', '사용자 지정'),
  _Forbidden('suite_wide_terms', 'clock', 'ko', '클록'),
  _Forbidden('suite_wide_terms', 'open_core_edition', 'zh', '开源核心版'),
];

Map<String, dynamic> _json(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

void main() {
  final glossary = _json(_glossaryPath);

  test('every forbidden rendering contradicts what the glossary says', () {
    for (final rule in _forbidden) {
      final section = glossary[rule.section] as Map<String, dynamic>;
      final entry = section[rule.term] as Map<String, dynamic>?;
      expect(
        entry,
        isNotNull,
        reason: '${rule.section}.${rule.term} is missing from $_glossaryPath',
      );
      final rendering = entry![rule.locale] as String;
      expect(
        rule.regExp.hasMatch(rendering),
        isFalse,
        reason:
            'the glossary rendering "$rendering" for ${rule.term} matches '
            'the forbidden pattern ${rule.pattern}; the rule is stale',
      );
    }
  });

  test('no message uses a rendering the glossary rules out', () {
    final offenders = <String>[];
    for (final rule in _forbidden) {
      for (final path in _arbFilesByLocale[rule.locale]!) {
        final arb = _json(path);
        for (final MapEntry(:key, :value) in arb.entries) {
          if (key.startsWith('@') || value is! String) continue;
          if (rule.regExp.hasMatch(value)) {
            final section = glossary[rule.section] as Map<String, dynamic>;
            final wanted =
                (section[rule.term] as Map<String, dynamic>)[rule.locale];
            offenders.add('$path $key: ${rule.pattern} (glossary: $wanted)');
          }
        }
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('glossary.json carries every suite-wide term in the house style', () {
    final instructions = File(_instructionsPath).readAsStringSync();
    final start = instructions.indexOf('## Suite-Wide Terms');
    expect(start, isNot(-1), reason: 'suite-wide table not found');
    final end = instructions.indexOf('\n## ', start + 1);
    final table = instructions.substring(start, end == -1 ? null : end);

    // Rows of `| English | zh-CN | ja | ko |`, skipping the header and rule.
    final rows = table
        .split('\n')
        .where((l) => l.startsWith('|') && !l.startsWith('|--'))
        .skip(1)
        .map(
          (l) => l
              .split('|')
              .map((c) => c.trim())
              .where((c) => c.isNotEmpty)
              .toList(),
        )
        .where((cells) => cells.length == 4)
        .toList();
    expect(rows, isNotEmpty);

    String bare(String cell) =>
        cell.replaceAll(RegExp(r'\s*\(.*\)$'), '').trim();

    final suiteWide = (glossary['suite_wide_terms'] as Map<String, dynamic>)
        .values
        .whereType<Map<String, dynamic>>()
        .toList();
    final missing = <String>[];
    for (final cells in rows) {
      final zh = bare(cells[1]);
      final ja = bare(cells[2]);
      final ko = bare(cells[3]);
      final found = suiteWide.any(
        (e) => e['zh'] == zh && e['ja'] == ja && e['ko'] == ko,
      );
      if (!found) missing.add('${cells[0]} ($zh / $ja / $ko)');
    }
    expect(
      missing,
      isEmpty,
      reason:
          'suite-wide terms in $_instructionsPath missing from '
          '$_glossaryPath: ${missing.join(', ')}',
    );
  });
}
