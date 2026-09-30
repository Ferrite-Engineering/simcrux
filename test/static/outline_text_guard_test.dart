// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Static guard: a ColorScheme's `outline` token never colors TEXT.
//
// `outline` is a Material 3 BORDER token — the hairline around an
// `OutlineInputBorder`, a card edge, a divider, a painter's stroke. The
// suite's UI conventions are explicit that de-emphasised text must use
// `onSurfaceVariant` instead: `outline` was never chosen against WCAG
// text-contrast minimums, only against adjacent surface colors, so using it
// to color text reads as a contrast failure. A paid accessibility re-check
// is the reason this sweep happened now; this guard is what keeps a new
// violation from shipping quietly afterward.
//
// A 2026-09 sweep of this repository found the token used as a text color
// in four places, now fixed to `onSurfaceVariant`:
//  - three settings rows whose "stopped"/"disabled" status label took its
//    color straight from a `TextStyle`, and
//  - `SimcruxColors.statusColor`'s `TestStatus.cancelled` case, which reads
//    like a plain status-to-hue mapping but is consumed by `WebStatusChip`
//    as the color of the chip's own `Text` label (`lib/web/
//    web_status_chip.dart`), in addition to two legitimate icon-tint call
//    sites and one legitimate cell-fill call site that also read it. A
//    single call three hops downstream turning into a text color is exactly
//    the shape a receiver-agnostic text search like this one cannot see on
//    its own — the token search below only ever finds the literal
//    `.outline` at the mapping's definition, and fixing the definition
//    fixes every consumer, text and non-text alike.
//
// What remains, and is pinned in `_exemptions`, is one unrelated,
// single-purpose helper whose only caller uses it for a cell fill.
//
// ## Heuristic, and why
//
// A precise "does this feed a `TextStyle.color`?" check needs a type-aware
// analysis this guard doesn't have. Instead it scans for the bare,
// word-bounded token `.outline` (so `.outlineVariant` never matches — there
// is no word boundary between "e" and "V" — and neither does an `Icons.*`
// name like `help_outline`, since nothing precedes "outline" there with a
// literal `.`) under any receiver: `colorScheme.outline`, `theme.colorScheme
// .outline`, a local `scheme.outline`, `cs.outline`, and so on — the token
// match is deliberately receiver-agnostic, because the sweep that produced
// this guard found more than one spelling in use across the suite.
//
// This also means the guard cannot by itself tell a color helper's
// definition from its call sites: it can only flag the literal token where
// it is written. When a helper's return value feeds both text and non-text
// consumers (as `SimcruxColors.statusColor` did), the fix lives at the
// helper's definition, not at a particular call site, and there is nothing
// left for this guard to pin once that is done.
//
// Every surviving occurrence must be pinned in `_exemptions` with the exact
// file, line, and trimmed line content, plus a reason it is NOT a text-color
// use. If the file changes around that line, the recorded content stops
// matching and the guard re-flags whatever now sits there instead of
// silently carrying the exemption forward — a new, unreviewed use of the
// token (text or not) always fails until someone looks at it.
//
// ## Scope
//
// `lib/` only, this repository. Each of the suite's open cores keeps its
// own copy of this guard, scoped to its own `lib/`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final exemptions = <_Exemption>[
    const _Exemption(
      file: 'lib/features/inspector/widgets/test_trend_sparkline.dart',
      line: 72,
      expectedTrimmed: 'return scheme.outline;',
      reason:
          'a private _colorFor() helper whose only caller feeds a '
          "Container's BoxDecoration.color (the sparkline cell fill) — a "
          'fill, not text. Unrelated to SimcruxColors.statusColor.',
    ),
  ];

  test('the outline token is never used to color text', () {
    final root = Directory('lib');
    expect(
      root.existsSync(),
      isTrue,
      reason:
          'lib/ must exist for this guard to mean anything — run from the '
          'repository root',
    );

    // Word-bounded, receiver-agnostic: matches `colorScheme.outline`,
    // `theme.colorScheme.outline`, `scheme.outline`, `cs.outline`, ... but
    // never `.outlineVariant` (no boundary between "e" and "V") and never an
    // `Icons.*_outline` name (no literal "." precedes "outline" there).
    final tokenPattern = RegExp(r'\.outline\b(?!Variant)');

    final exemptByFile = <String, List<_Exemption>>{};
    for (final e in exemptions) {
      exemptByFile.putIfAbsent(e.file, () => []).add(e);
    }

    final offenders = <String>[];
    var filesScanned = 0;
    var tokensSeen = 0;

    for (final entity in root.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final relPath = entity.path.replaceAll(r'\', '/');
      filesScanned++;

      final lines = entity.readAsStringSync().split('\n');
      final fileExemptions = exemptByFile[relPath] ?? const [];
      for (var i = 0; i < lines.length; i++) {
        if (!tokenPattern.hasMatch(lines[i])) continue;
        tokensSeen++;

        final lineNo = i + 1;
        final trimmed = lines[i].trim();
        final isExempt = fileExemptions.any(
          (e) => e.line == lineNo && e.expectedTrimmed == trimmed,
        );
        if (isExempt) continue;

        offenders.add('$relPath:$lineNo: $trimmed');
      }
    }

    // Non-vacuity: a broken regex or a wrong working directory would make
    // this guard pass by finding nothing at all.
    expect(
      filesScanned,
      greaterThan(100),
      reason:
          'the source walk collected implausibly few files — check the '
          'working directory (must run from the repository root)',
    );
    expect(
      tokensSeen,
      greaterThanOrEqualTo(exemptions.length),
      reason:
          'expected to see at least the ${exemptions.length} known '
          'exempted outline sites; the scan found $tokensSeen — is the '
          'regex or the file walk broken?',
    );

    expect(
      offenders,
      isEmpty,
      reason:
          'the outline token is used where onSurfaceVariant belongs (or an '
          "unreviewed new use that needs an entry in this guard's "
          'exemption list, with a reason):\n\n${offenders.join('\n')}',
    );
  });

  test('the token pattern matches the shapes it must and none it must not', () {
    final tokenPattern = RegExp(r'\.outline\b(?!Variant)');
    for (final positive in <String>[
      'color: theme.colorScheme.outline,',
      'color: colorScheme.outline,',
      'return scheme.outline;',
      'color: cs.outline,',
    ]) {
      expect(
        tokenPattern.hasMatch(positive),
        isTrue,
        reason: 'should have matched: $positive',
      );
    }
    for (final negative in <String>[
      'theme.colorScheme.outlineVariant',
      'icon: Icons.help_outline,',
      'border: const OutlineInputBorder()',
    ]) {
      expect(
        tokenPattern.hasMatch(negative),
        isFalse,
        reason: 'should not have matched: $negative',
      );
    }
  });
}

class _Exemption {
  const _Exemption({
    required this.file,
    required this.line,
    required this.expectedTrimmed,
    required this.reason,
  });

  final String file;
  final int line;
  final String expectedTrimmed;

  /// Not read by the check itself — kept for a human auditing the list.
  final String reason;
}
