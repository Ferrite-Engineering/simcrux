// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Static guard for the Crux suite CJK localization house style.
// Canonical spec: wavecrux/.claude/instructions.md (+ assets/l10n/glossary.json).
// Identical copies of this test live in every suite repo (core and Pro overlay).
//
// Guards:
//  1. Key parity — every locale file carries exactly the message keys of app_en.arb.
//  2. zh mirror — app_zh.arb is byte-identical to app_zh_CN.arb except @@locale.
//     (Without it, the Pro overlay's app_zh.arb once drifted and picked up
//     Traditional Chinese.)
//  3. ICU plurals — every plural message in every locale includes an =1 case.
//  4. Ellipsis — no three-dot "..." anywhere; U+2026 only.
//  5. zh punctuation width — no ASCII , ; ? : after a CJK ideograph or closing quote/bracket.
//  6. ja punctuation width — no ASCII ? directly after kana/kanji.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _locales = ['en', 'zh_CN', 'zh', 'ja', 'ko'];

Map<String, dynamic> _load(String locale) {
  final file = File('lib/l10n/app_$locale.arb');
  // Plain throw (not expect): _load runs at declare time, where flutter_test's
  // expect() throws OutsideTestException even on success.
  if (!file.existsSync()) {
    throw StateError('missing ${file.path}');
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

Iterable<String> _messageKeys(Map<String, dynamic> arb) =>
    arb.keys.where((k) => !k.startsWith('@'));

void main() {
  final arbs = {for (final l in _locales) l: _load(l)};

  test('all locales carry exactly the en message keys', () {
    final enKeys = _messageKeys(arbs['en']!).toSet();
    for (final locale in _locales.skip(1)) {
      final keys = _messageKeys(arbs[locale]!).toSet();
      expect(
        keys.difference(enKeys),
        isEmpty,
        reason: 'app_$locale.arb has keys missing from app_en.arb',
      );
      expect(
        enKeys.difference(keys),
        isEmpty,
        reason: 'app_$locale.arb is missing keys present in app_en.arb',
      );
    }
  });

  test('app_zh.arb mirrors app_zh_CN.arb exactly (except @@locale)', () {
    final zhCn = arbs['zh_CN']!;
    final zh = arbs['zh']!;
    expect(zh['@@locale'], 'zh');
    expect(zhCn['@@locale'], 'zh_CN');
    final zhCnRest = Map.of(zhCn)..remove('@@locale');
    final zhRest = Map.of(zh)..remove('@@locale');
    expect(
      const JsonEncoder.withIndent('  ').convert(zhRest),
      const JsonEncoder.withIndent('  ').convert(zhCnRest),
      reason:
          'app_zh.arb has drifted from app_zh_CN.arb — every edit to '
          'app_zh_CN.arb must be applied to app_zh.arb verbatim',
    );
  });

  test('every ICU plural includes an =1 case', () {
    final pluralRe = RegExp(r'\{\s*\w+\s*,\s*plural\s*,');
    final eq1Re = RegExp(r'=1\s*\{');
    for (final locale in _locales) {
      for (final key in _messageKeys(arbs[locale]!)) {
        final value = arbs[locale]![key];
        if (value is! String || !pluralRe.hasMatch(value)) continue;
        expect(
          eq1Re.hasMatch(value),
          isTrue,
          reason:
              'app_$locale.arb::$key: plural without =1 case '
              '(house style requires both =1 and other)',
        );
      }
    }
  });

  test('no three-dot ellipsis — use U+2026', () {
    for (final locale in _locales) {
      for (final key in _messageKeys(arbs[locale]!)) {
        final value = arbs[locale]![key];
        if (value is! String) continue;
        expect(
          value.contains('...'),
          isFalse,
          reason: 'app_$locale.arb::$key uses "..." — replace with …',
        );
      }
    }
  });

  test('zh: no half-width , ; ? : directly after a CJK ideograph', () {
    final re = RegExp('[一-鿿”』」）][,;?:]');
    for (final locale in ['zh_CN', 'zh']) {
      for (final key in _messageKeys(arbs[locale]!)) {
        final value = arbs[locale]![key];
        if (value is! String) continue;
        final m = re.firstMatch(value);
        expect(
          m,
          isNull,
          reason:
              'app_$locale.arb::$key: half-width "${m?.group(0)}" after '
              'CJK text — use full-width ，；？：',
        );
      }
    }
  });

  test('ja: no half-width ? directly after kana/kanji', () {
    final re = RegExp(r'[぀-ヿ一-鿿”』」）]\?');
    for (final key in _messageKeys(arbs['ja']!)) {
      final value = arbs['ja']![key];
      if (value is! String) continue;
      final m = re.firstMatch(value);
      expect(
        m,
        isNull,
        reason:
            'app_ja.arb::$key: half-width "?" after Japanese text — '
            'use full-width ？',
      );
    }
  });
}
