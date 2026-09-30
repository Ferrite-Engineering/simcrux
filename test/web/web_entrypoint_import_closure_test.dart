// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The read-only web dashboard (`lib/main_web.dart`, deployed to
/// app.simcrux.app) must not reach CXP.
///
/// CXP discovery resolves its manifest directory from the process
/// environment (`sharedCxpManifestDirectory` in `crux_cxp`), which throws in a
/// browser, and the CXP server binds a socket. Walks the entrypoint's import
/// closure inside this package and fails if any file in it imports
/// `crux_cxp` or SimCrux's CXP services — the way a future "Debug in
/// WaveCrux" button on the web inspector would bring startup down.
void main() {
  test('lib/main_web.dart never imports CXP', () {
    final importPattern = RegExp(
      r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
    );
    final visited = <String>{};
    final offenders = <String>[];
    final pending = <String>['lib/main_web.dart'];

    while (pending.isNotEmpty) {
      final path = pending.removeLast();
      if (!visited.add(path)) continue;
      final file = File(path);
      expect(file.existsSync(), isTrue, reason: '$path is missing');
      for (final line in file.readAsLinesSync()) {
        final match = importPattern.firstMatch(line);
        if (match == null) continue;
        final uri = match.group(1)!;
        if (uri.startsWith('package:crux_cxp') ||
            uri.contains('/services/remote/cxp/') ||
            uri.contains('/features/remote/')) {
          offenders.add('$path imports $uri');
        }
        if (uri.startsWith('package:simcrux/')) {
          pending.add(p.join('lib', uri.substring('package:simcrux/'.length)));
        } else if (!uri.contains(':')) {
          pending.add(p.normalize(p.join(p.dirname(path), uri)));
        }
      }
    }

    expect(
      visited.length,
      greaterThan(5),
      reason: 'the walk should reach the web screen, loaders and widgets',
    );
    expect(offenders, isEmpty);
  });
}
