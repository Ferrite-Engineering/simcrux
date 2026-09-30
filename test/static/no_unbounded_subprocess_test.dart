// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The SimCrux half of a suite-wide guard.
///
/// NetCrux carries the same shape: the
/// subprocess seam is one place, it is bounded and killable, and a static
/// guard stops a second spawn site appearing beside it. SimCrux spawns more
/// processes than any other product in the suite — every simulator driver is
/// a subprocess, and Cocotb's is a *tree* of them — and had no such guard.
///
/// The seam here is `ProcessReaper` (`lib/services/job_scheduler/`), reached
/// through the `ProcessLauncher` hook the scheduler injects. The reaper exists
/// because killing the parent PID is not enough: Cocotb spawns `make`, which
/// forks `python`, which forks the simulator, so a driver that called
/// `Process.start` itself would leave grandchildren running after a cancel or
/// a timeout. Those orphans hold simulator licences and keep writing to the
/// results directory — a failure that shows up as a mysteriously locked
/// licence pool an hour later, not as a stack trace.
///
/// Scoped to `lib/services/simulator/`, the drivers. Elsewhere a subprocess is
/// a different thing (the inspector's editor launcher opens the user's editor
/// detached, and must *not* be reaped), and the scheduler directory is where
/// the seam itself lives.
void main() {
  test('no raw Process spawn under lib/services/simulator/', () {
    final dir = Directory('lib/services/simulator');
    expect(
      dir.existsSync(),
      isTrue,
      reason: 'simulator services dir must exist',
    );

    final offenders = <String>[];
    final spawn = RegExp(r'Process\s*\.\s*(run|start|runSync)\s*\(');
    for (final file
        in dir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .where((f) => !f.path.endsWith('.g.dart'))) {
      final rel = p.relative(file.path);
      if (_allowed.contains(p.basename(rel))) continue;
      final source = file.readAsStringSync();
      for (final match in spawn.allMatches(source)) {
        final line =
            '\n'.allMatches(source.substring(0, match.start)).length + 1;
        offenders.add('$rel:$line');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'A raw Process spawn appeared under lib/services/simulator/. '
          'Simulator invocations go through the ProcessLauncher hook the '
          'scheduler injects, so ProcessReaper can terminate the whole '
          'descendant tree on timeout or cancel — spawning directly orphans '
          'grandchildren that keep holding simulator licences.\n'
          '${offenders.join('\n')}',
    );
  });

  /// The allowlist is asserted, not just declared.
  ///
  /// An entry that stops being needed is an entry that would silently excuse a
  /// future spawn in the same file. This fails when one goes stale.
  test('every allowlisted file still spawns something', () {
    final spawn = RegExp(r'Process\s*\.\s*(run|start|runSync)\s*\(');
    for (final name in _allowed) {
      final matches = Directory('lib/services/simulator')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => p.basename(f.path) == name);
      expect(
        matches,
        isNotEmpty,
        reason: '$name is allowlisted but no longer exists. Drop the entry.',
      );
      expect(
        spawn.hasMatch(matches.first.readAsStringSync()),
        isTrue,
        reason:
            '$name is allowlisted but no longer spawns a process. Drop the '
            'entry, or it will excuse the next spawn added to that file.',
      );
    }
  });
}

/// Files under `lib/services/simulator/` permitted to spawn directly.
///
/// None. Every driver in the directory routes through the injected launcher,
/// which is what makes the guard cheap to hold now and expensive to add
/// later. The Windows `reg query` that discovers installed toolchains used to
/// be the one entry; that PATH discovery now lives in `crux_io`
/// (`engineSearchDirs`), outside the scanned directory, and the one copy
/// serves every product that spawns an engine.
const _allowed = <String>{};
