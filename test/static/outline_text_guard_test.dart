// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Static guard: a ColorScheme's `outline` token never colours TEXT.
//
// `outline` is a Material 3 BORDER token: the hairline around an
// `OutlineInputBorder`, a card edge, a divider, a painter's stroke. The
// suite's UI conventions say de-emphasised text uses `onSurfaceVariant`
// instead, because `outline` was never chosen against WCAG text-contrast
// minimums, only against adjacent surface colours. A paid accessibility
// re-check is why the 2026-09 sweep happened; this guard keeps a new
// violation from shipping quietly afterward.
//
// The scanner is `crux_guards`' `cruxAuditOutlineText`: it reads the syntax
// tree, so `.outlineVariant`, an `Icons.*_outline` name and a mention in a
// comment never match, and it cannot by itself tell a colour helper's
// definition from its call sites. When a helper feeds both text and non-text
// consumers (as `SimcruxColors.statusColor` once did), the fix lives at the
// definition. Every surviving use is pinned below by file, line and trimmed
// text with the reason it is not a text colour; an exemption that no longer
// matches is itself a finding, so an unreviewed use always fails until
// someone looks at it.

import 'package:crux_guards/crux_guards.dart';
import 'package:flutter_test/flutter_test.dart';

import 'crux_guard_sources.dart';

const List<CruxOutlineExemption> _exemptions = <CruxOutlineExemption>[
  CruxOutlineExemption(
    file: 'lib/features/inspector/widgets/test_trend_sparkline.dart',
    line: 72,
    expectedTrimmed: 'return scheme.outline;',
    reason:
        'a private _colorFor() helper whose only caller feeds a '
        "Container's BoxDecoration.color (the sparkline cell fill), a "
        'fill, not text. Unrelated to SimcruxColors.statusColor.',
  ),
];

void main() {
  test('the outline token is never used to colour text', () {
    final result = cruxAuditOutlineText(
      sources: cruxGuardSourcesUnder('lib'),
      exemptions: _exemptions,
    );
    // Non-vacuity first: a wrong working directory or a broken walk would
    // pass by finding nothing at all.
    expect(
      result.filesScanned,
      greaterThan(100),
      reason: 'the source walk collected implausibly few files',
    );
    expect(
      result.matchesSeen,
      greaterThanOrEqualTo(_exemptions.length),
      reason:
          'expected to see at least the ${_exemptions.length} pinned outline '
          'sites; the scan found ${result.matchesSeen}',
    );
    expect(
      result.isClean,
      isTrue,
      reason:
          'the outline token is used where onSurfaceVariant belongs (or an '
          'unreviewed new use that needs an entry in _exemptions, with a '
          'reason):\n\n${result.describe()}',
    );
  });
}
