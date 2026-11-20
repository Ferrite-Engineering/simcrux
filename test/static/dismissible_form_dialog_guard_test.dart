// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'dart:io';

import 'package:crux_guards/crux_guards.dart';
import 'package:flutter_test/flutter_test.dart';

// A dialog that holds typed input closes by a deliberate act (Cancel, the
// close button, Escape), never a stray click on the scrim, which discards what
// the user typed. Every such opener passes `barrierDismissible: false`
// (`isDismissible: false` for a bottom sheet). The scanner is crux_guards'
// `cruxAuditDismissibleFormDialogs`; a form that deliberately stays
// dismissible goes in `allowances:` with the reason nothing is lost.

List<CruxGuardSource> _dartFiles(String root) => [
  if (Directory(root).existsSync())
    for (final f in Directory(root).listSync(recursive: true).whereType<File>())
      if (f.path.endsWith('.dart') && !f.path.endsWith('.g.dart'))
        CruxGuardSource(
          path: f.path.replaceAll(r'\', '/'),
          source: f.readAsStringSync(),
        ),
];

void main() {
  test('a dialog holding typed input is not dismissed by a scrim click', () {
    final shared = <CruxGuardSource>[];
    for (final pkg in Directory('crux-shared/packages').listSync()) {
      if (pkg is Directory) shared.addAll(_dartFiles('${pkg.path}/lib'));
    }

    final result = cruxAuditDismissibleFormDialogs(
      sources: _dartFiles('lib'),
      classSources: shared,
    );

    expect(result.filesScanned, greaterThan(100));
    expect(result.matchesSeen, greaterThan(0));
    expect(result.isClean, isTrue, reason: result.describe());
  });
}
