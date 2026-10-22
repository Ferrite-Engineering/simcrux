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
/// Scoped to the drivers: `lib/services/simulator/` and the implementation
/// flows in `lib/services/flow/` (LibreLane's tree is Yosys, OpenROAD, Magic,
/// KLayout and Netgen, and a cancel must reach all of them). Elsewhere a
/// subprocess is a different thing (the inspector's editor launcher opens the
/// user's editor detached, and must *not* be reaped), and the scheduler
/// directory is where the seam itself lives.
void main() {
  for (final dirPath in _scanned) {
    test('no raw Process spawn under $dirPath/', () {
      final dir = Directory(dirPath);
      expect(dir.existsSync(), isTrue, reason: '$dirPath must exist');

      final offenders = <String>[];
      for (final file
          in dir
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))
              .where((f) => !f.path.endsWith('.g.dart'))) {
        final rel = p.relative(file.path);
        if (_allowed.contains(p.basename(rel))) continue;
        final source = file.readAsStringSync();
        for (final match in _spawn.allMatches(source)) {
          final line =
              '\n'.allMatches(source.substring(0, match.start)).length + 1;
          offenders.add('$rel:$line');
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'A raw Process spawn appeared under $dirPath/. Driver invocations '
            'go through the ProcessLauncher hook the scheduler injects (or the '
            "driver's ProcessReaper), so the whole descendant tree can be "
            'terminated on timeout or cancel; spawning directly orphans '
            'grandchildren.\n${offenders.join('\n')}',
      );
    });
  }

  /// The allowlist is asserted, not just declared.
  ///
  /// An entry that stops being needed is an entry that would silently excuse a
  /// future spawn in the same file. This fails when one goes stale.
  test('every allowlisted file still spawns something', () {
    for (final name in _allowed) {
      final matches = <File>[
        for (final dirPath in _scanned)
          ...Directory(dirPath)
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => p.basename(f.path) == name),
      ];
      expect(
        matches,
        isNotEmpty,
        reason: '$name is allowlisted but no longer exists. Drop the entry.',
      );
      expect(
        _spawn.hasMatch(matches.first.readAsStringSync()),
        isTrue,
        reason:
            '$name is allowlisted but no longer spawns a process. Drop the '
            'entry, or it will excuse the next spawn added to that file.',
      );
    }
  });
}

final RegExp _spawn = RegExp(r'Process\s*\.\s*(run|start|runSync)\s*\(');

/// The directories scanned.
const _scanned = <String>['lib/services/simulator', 'lib/services/flow'];

/// Files under the scanned directories permitted to spawn directly.
///
/// One. `flow_handoff_launcher.dart` hands a run to KLayout, OpenROAD or
/// nextpnr's GUI: the viewer is the user's window, started detached by
/// design, and must outlive SimCrux rather than be reaped with a run. Every
/// driver routes through the injected launcher. The Windows `reg query` that
/// discovers installed toolchains used to be an entry; that PATH discovery
/// now lives in `crux_io` (`engineSearchDirs`), outside the scanned
/// directories.
const _allowed = <String>{'flow_handoff_launcher.dart'};
