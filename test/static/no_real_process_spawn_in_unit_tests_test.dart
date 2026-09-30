// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The load-bearing guard. Unit tests under `test/services/**` must
/// go through the `FakeProcessRunner` / `ProcessReaper` seam, never spawn a
/// real OS process. Real `Process.start` / `Process.run` belong only in
/// `test/integration/**` (which correctly skip when the simulator binary
/// is absent). This keeps the fast suite hermetic and platform-agnostic.
///
/// MUTATION: adding a `Process.start(...)` / `Process.run(...)` line to any
/// `test/services/**` file makes this guard red.
void main() {
  test('no test/services file spawns a real OS process', () {
    final root = Directory('test/services');
    expect(
      root.existsSync(),
      isTrue,
      reason: 'run from the package root (cwd = simcrux/)',
    );

    final offenders = <String>[];
    final spawnPattern = RegExp(r'Process\.(start|run)\s*\(');
    for (final entity in root.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      for (final match in spawnPattern.allMatches(source)) {
        final line =
            '\n'.allMatches(source.substring(0, match.start)).length + 1;
        offenders.add('${entity.path}:$line');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'real process spawns must live in test/integration/**, '
          'behind the simulator-absent skip — found:\n${offenders.join('\n')}',
    );
  });
}
