// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Path assertions that mean the same thing on every runner.
///
/// A path the product produced — `Directory.listSync`, a sqflite
/// `Database.path`, anything absolutised by `package:path` — is spelled with
/// the platform's separator. Compared against one spelled by hand with `/`,
/// it matches on Linux and macOS and fails on Windows, and the suite only
/// finds out in the weekly cross-platform sweep, days after the commit.
///
/// Both shapes below are ones that have actually cost the suite a run.
///
/// The rule is NOT "never interpolate a path". `File('${dir.path}/x.txt')`
/// is fine — Dart accepts `/` in a Windows path for I/O — and a `path` that
/// never went near a filesystem, like the CXP element paths the remote tests
/// assert on, is the same string everywhere. The defect is narrower than
/// either, and always the same shape: a path the *platform* spelled, checked
/// against one a person spelled.
void main() {
  // A `.path` is only spelled by the platform if the platform produced it, so
  // scan a file only once something in it has been through `dart:io`.
  final touchesFilesystem = RegExp(
    r'Directory\(|createTempSync|listSync|systemTemp|resolveSymbolicLinks',
  );

  // Shape 1 — a product-produced path matched against a `/`-spelled literal.
  //
  // `gated_surfaces_wired_test` did this: it walked `lib/` and compared
  // `entity.path` to `'lib/core/license/pro_gate.dart'`. On Windows the left
  // side reads `lib\core\…`, so the skip never fired, the `overrides.dart`
  // removal never fired, and every gated surface in the tree reported as
  // unguarded. A guard that had quietly stopped guarding.
  final pathVersusLiteral = RegExp(
    r"""\.path\.(?:endsWith|startsWith|contains)\(\s*r?'[^']*/[^']*'""",
  );

  // Shape 2 — a path built by interpolation, then used as an EXPECTED value.
  //
  // `sql_recovery_test` did this: `final dbPath = '${tmp.path}/corrupt.db';`
  // and then `expect(store.path, dbPath)`. Building it that way is harmless;
  // asserting the product echoes it back verbatim is not, because the product
  // returns the absolutised, platform-spelled form.
  //
  // Note this is deliberately about variables, not literals. In every one of
  // these failures the expected side was a variable — a rule written against
  // string literals would have caught none of them.
  final interpolatedPathBinding = RegExp(
    r"""(?:final|var|const)\s+(\w+)\s*=\s*'[^']*\$\{[\w.]+\.path\}/""",
  );

  test('path assertions do not hard-code the POSIX separator', () {
    final offenders = <String>[];

    for (final entity in Directory('test').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // Compare in one spelling — the very thing this test is about.
      final relative = entity.uri.pathSegments.join('/');
      if (relative.endsWith('static/portable_path_assertions_test.dart')) {
        continue;
      }

      final source = entity.readAsStringSync();
      if (!touchesFilesystem.hasMatch(source)) continue;

      final handBuilt = interpolatedPathBinding
          .allMatches(source)
          .map((m) => m.group(1)!)
          .toSet();
      final expectedIsHandBuilt = handBuilt.isEmpty
          ? null
          : RegExp('expect\\([^;]*,\\s*(${handBuilt.join('|')})\\s*[,)]');

      final lines = source.split('\n');
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;
        if (pathVersusLiteral.hasMatch(line) ||
            (expectedIsHandBuilt?.hasMatch(line) ?? false)) {
          offenders.add('$relative:${i + 1}\n    ${line.trim()}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These check a path the platform spelled against one spelled by '
          'hand, so they assert something different on Windows than they do '
          'here — usually something weaker, and silently.\n\n'
          'Build the expected path with `p.join(dir, name)`, or compare with '
          '`p.equals(a, b)`. If the assertion is genuinely about POSIX '
          'spelling, normalise the left side first: '
          '`p.split(x.path).join("/")`.\n\n'
          '${offenders.join('\n')}',
    );
  });
}
