// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Structural guardrail for the locale-sweep convention (wavecrux/CLAUDE.md:
// "Screens and interactive widgets must include a locale sweep that renders
// in en, zh_CN, ja, and ko and asserts no exceptions").
//
// THE PROBLEM THIS SOLVES: the convention is easy to satisfy in name only.
// Widget tests accumulated sections literally headed "── locale sweep ──"
// that rendered nothing but `en`, because nothing mechanically checked that a
// CJK locale was actually exercised — roughly a third of the widget-test
// suite had drifted into single-locale smoke tests before this guard existed.
// The guard makes that drift structurally visible: it fails CI the moment a
// new (or edited) screen/widget test file
// pumps a `MaterialApp` with localization delegates but never demonstrably
// exercises a CJK locale.
//
// WHAT COUNTS AS COMPLIANT for a file that pumps a `MaterialApp` with
// `localizationsDelegates` (the signal that it renders through L10N):
//   1. It references a CJK sweep locale literally — `Locale('zh', 'CN')`,
//      `Locale('zh')`, or the string-locale-code form (`'zh_CN'`, `'zh'`) —
//      the two idioms the compliant files in this repo use.
//   2. It sweeps the full `L10N.supportedLocales` list via
//      `for (final locale in L10N.supportedLocales)` (a superset of the
//      four sweep locales — see fsdb_conversion_dialog_test.dart).
//   3. It carries a `LOCALE_SWEEP_EXEMPT: <reason>` comment — for tests that
//      are legitimately render-object, golden, or gesture-math (no
//      locale-sensitive text rendered), or a state-machine/timing regression
//      harness where the surface under test is not text rendering. Every use
//      is a deliberate, reviewable opt-out with its reason in the diff — not
//      a silent skip.
//
// This is intentionally a STRUCTURAL check (regex over source), not a
// semantic one — it cannot verify the sweep actually asserts anything
// meaningful, only that the file demonstrably touches a CJK locale or
// declares why it doesn't need to. That mirrors every other static guard in
// this directory (e.g. captured_fixture_licenses_test.dart): cheap to run,
// catches the common accidental regression, not proof against a
// determined bad-faith bypass.
//
// When this test fails on a new/edited file: add a real locale sweep
// following the idiom the codebase already uses (see e.g.
// `test/features/viewer/widgets/status_bar_test.dart` or
// `test/features/workspace/widgets/recovery_banner_host_test.dart` for the
// "add a NEW additive sweep group without touching existing tests" pattern),
// or — only if the file is genuinely render-object/golden/gesture-math/a
// non-UI regression harness — add a `LOCALE_SWEEP_EXEMPT:` comment
// explaining why.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _zhLiteral = RegExp(r"""'zh'|"zh"|zh_CN|zh',\s*'CN'""");
final _supportedLocalesSweep = RegExp(
  r'for\s*\(\s*final\s+\w+\s+in\s+L10N(Pro)?\.supportedLocales',
);
const _exemptMarker = 'LOCALE_SWEEP_EXEMPT';

void main() {
  test(
    'every screen/widget test that renders through L10N demonstrably '
    'exercises a CJK locale (or declares a LOCALE_SWEEP_EXEMPT reason)',
    () {
      final testDir = Directory('test/features');
      expect(
        testDir.existsSync(),
        isTrue,
        reason: 'run this test from the package root (flutter test)',
      );

      final violations = <String>[];

      for (final entity in testDir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('_test.dart')) continue;
        final path = entity.path.replaceAll(r'\', '/');
        // Only screens/ and widgets/ subtrees carry the locale-sweep
        // obligation — providers/services/domain-model tests render nothing.
        if (!RegExp('/(screens|widgets)/').hasMatch(path)) continue;

        final src = entity.readAsStringSync();
        // Only files that actually pump a MaterialApp with localization
        // delegates render through L10N in the first place.
        if (!src.contains('localizationsDelegates')) continue;

        final compliant =
            _zhLiteral.hasMatch(src) ||
            _supportedLocalesSweep.hasMatch(src) ||
            src.contains(_exemptMarker);
        if (!compliant) violations.add(path);
      }

      expect(
        violations,
        isEmpty,
        reason:
            'These screen/widget test files pump a MaterialApp with '
            'localizationsDelegates but never demonstrably exercise a CJK '
            'locale sweep, and carry no LOCALE_SWEEP_EXEMPT reason:\n'
            '${violations.join('\n')}',
      );
    },
  );
}
