// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/os_detritus.dart';

/// Every file in a fixture corpus must actually be **in the repository**.
///
/// This guard exists because "the fixture is on my disk" and "the fixture
/// is committed" are different facts, and only the second one is true for
/// CI. `.gitignore`'s blanket `*.log` (Flutter's own boilerplate) silently
/// swallowed all seven `verification/fixtures/riscv_formal/*/sby.log`
/// files. Every developer had them — the generator writes them — so the
/// suite was green locally, while `ubuntu-latest` cloned a corpus whose
/// logs did not exist and replayed empty text: every verdict came back
/// `NO_OUTCOME`, and 18 tests across the `riscv_formal` driver and fixture
/// suites went red for a reason that looked like a platform difference and
/// was not one.
///
/// An existence check cannot catch this — the files exist locally. The
/// only question that distinguishes the two states is the one asked here:
/// does `git ls-files` know about them?
///
/// MUTATION: `git rm --cached` any corpus file, or re-add a `.gitignore`
/// rule that swallows one, and this goes red on every platform — including
/// the machine that still has the file sitting on disk.
void main() {
  // Roots whose entire contents are committed data. `lib/` and `test/`
  // source are not listed: they are covered by the fact that unimported
  // source cannot compile, whereas a fixture read at runtime fails silently
  // or, worse, degrades into a plausible-looking wrong answer.
  const corpora = <String>[
    'test/fixtures',
    'verification',
  ];

  /// Paths that are *correctly* untracked: per-project runtime artifacts
  /// the app itself writes next to a fixture project, and OS droppings
  /// (shared with the layout guard via [kOsDetritusFilenames], so the two
  /// cannot disagree about what counts as detritus).
  bool isLegitimatelyUntracked(String relative) {
    final segments = p.split(relative);
    return segments.contains('.simcrux') || isOsDetritus(segments.last);
  }

  /// The set of paths git tracks under [root], NUL-separated (`-z`) so a
  /// path containing a space or a quote round-trips instead of arriving
  /// git-quoted.
  Set<String> trackedUnder(String root) {
    final result = Process.runSync('git', [
      'ls-files',
      '-z',
      '--',
      root,
    ]);
    if (result.exitCode != 0) {
      fail(
        'this guard needs a git checkout (cwd = simcrux/): '
        'git ls-files failed with ${result.exitCode}: ${result.stderr}',
      );
    }
    return (result.stdout as String)
        .split('\u0000')
        .where((path) => path.isNotEmpty)
        .toSet();
  }

  for (final corpus in corpora) {
    test('$corpus: every committed fixture is actually committed', () {
      final root = Directory(corpus);
      expect(
        root.existsSync(),
        isTrue,
        reason: 'run from the package root (cwd = simcrux/)',
      );

      final tracked = trackedUnder(corpus);
      expect(
        tracked,
        isNotEmpty,
        reason: '$corpus has no tracked files at all — is git available?',
      );

      final missing = <String>[];
      for (final entity in root.listSync(recursive: true)) {
        if (entity is! File) continue;
        // git speaks POSIX separators on every platform.
        final relative = p.split(p.relative(entity.path)).join('/');
        if (isLegitimatelyUntracked(relative)) continue;
        if (!tracked.contains(relative)) missing.add(relative);
      }

      expect(
        missing,
        isEmpty,
        reason:
            'these fixture files exist on this machine but are NOT in the '
            'repository, so CI runs without them and the corpus silently '
            'shrinks. `git add` them, and check `.gitignore` is not '
            'swallowing them:\n${missing.join('\n')}',
      );
    });
  }

  test('the riscv_formal corpus logs are tracked, by name', () {
    // The list is spelled out rather than derived: the failure above is a
    // set difference and reads as noise, while this one names the file
    // that went missing. VERIFICATION_GUIDE.md §18.3's required cases, each with the log the
    // driver replays.
    const required = <String>[
      'insn_add_pass',
      'insn_sub_counterexample',
      'pc_fwd_unknown',
      'reg_timeout',
      'causal_error',
      'liveness_no_outcome',
      'cover_multi_trace',
    ];
    final tracked = trackedUnder('verification/fixtures/riscv_formal');
    for (final name in required) {
      expect(
        tracked,
        contains('verification/fixtures/riscv_formal/$name/sby.log'),
        reason:
            'the $name log is not in the repo — demo replay would read '
            'nothing and report NO_OUTCOME instead of its real verdict',
      );
    }
  });
}
