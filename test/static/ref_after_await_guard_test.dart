// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Static guard: a widget's `ref` is never used after an `await` without a
// `mounted` check in between.
//
// A `ConsumerState`'s `ref`, and a `WidgetRef` handed to a function, die
// with their widget. Read after an `await`, when the widget may be gone,
// they throw "Using ref when a widget is about to or has been unmounted",
// and the rest of the handler never runs: an audit record not written, a
// snack bar never shown, a flag left set for the session. The suite has
// fixed this class many times; `crux_guards`' `cruxAuditRefAfterAwait` is
// what stops it coming back. It reads syntax in source order, so a `ref`
// stored in a local and used later is not seen, and a `mounted` check that
// is read and ignored satisfies it; see the scanner's doc for the rest.
//
// The fix is to capture what the handler needs before the await (the
// notifier, the container, the value), or to check `mounted` (or
// `context.mounted`, `ref.mounted`) after it. An exemption names a function
// where the use is safe and says why; one that matches nothing is a finding.

import 'package:crux_guards/crux_guards.dart';
import 'package:flutter_test/flutter_test.dart';

import 'crux_guard_sources.dart';

const List<CruxRefAfterAwaitExemption> _exemptions =
    <CruxRefAfterAwaitExemption>[];

void main() {
  test("a widget's ref is never used after an await unguarded", () {
    final result = cruxAuditRefAfterAwait(
      sources: cruxGuardSourcesUnder('lib'),
      // Passed explicitly even though it matches the default: the empty list
      // is the claim being made, and a reader asking "what is waived here?"
      // must find the answer at the call.
      // ignore: avoid_redundant_argument_values
      exemptions: _exemptions,
    );
    expect(
      result.filesScanned,
      greaterThan(100),
      reason: 'the source walk collected implausibly few files',
    );
    expect(result.isClean, isTrue, reason: result.describe());
  });
}
