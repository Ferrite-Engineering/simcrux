// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards against the two CI-vs-local drift classes that broke the nightly
/// build during the 2026-07-21 remediation, both of which passed local
/// `flutter analyze` + `flutter test` but failed on a clean CI checkout:
///
///  1. The product's analyzer audited the vendored `crux-shared` submodule
///     (unresolved self-imports + analyzer-API skew) because
///     `analysis_options.yaml` did not exclude it. crux-shared has its own CI.
///  2. A `dart run build_runner` CI step referenced a `build_runner`
///     dependency that had been removed from `pubspec.yaml` (codegen was
///     dropped for manual providers), so the step failed with
///     "Could not find package build_runner".
///
/// Both are checkable offline from committed files, so this runs in the normal
/// test suite and fails at commit time instead of at 07:30 the next morning.
void main() {
  final root = _repoRoot();

  group('crux-shared submodule hygiene', () {
    test('analysis_options.yaml excludes the crux-shared submodule', () {
      final options = File('${root.path}/analysis_options.yaml');
      expect(
        options.existsSync(),
        isTrue,
        reason: 'analysis_options.yaml must exist at the repo root',
      );
      final text = options.readAsStringSync();
      // Only meaningful when crux-shared is actually vendored here.
      if (!Directory('${root.path}/crux-shared').existsSync()) {
        return;
      }
      expect(
        RegExp(r'-\s*crux-shared/\*\*').hasMatch(text),
        isTrue,
        reason:
            'The analyzer must exclude `crux-shared/**` — a product must '
            'not audit its vendored submodule (crux-shared has its own CI). '
            'Add `- crux-shared/**` under `analyzer: exclude:`.',
      );
    });

    test('build_runner CI step and pubspec dependency are consistent', () {
      final ci = File('${root.path}/.github/workflows/ci.yml');
      if (!ci.existsSync()) return; // some repos gate CI elsewhere
      final ciRunsBuildRunner = RegExp(
        r'dart run build_runner\b',
      ).hasMatch(ci.readAsStringSync());

      final pubspec = File('${root.path}/pubspec.yaml').readAsStringSync();
      final declaresBuildRunner = RegExp(
        r'^\s*build_runner\s*:',
        multiLine: true,
      ).hasMatch(pubspec);

      expect(
        ciRunsBuildRunner,
        declaresBuildRunner,
        reason: ciRunsBuildRunner
            ? 'CI runs `dart run build_runner` but pubspec.yaml no longer '
                  'declares build_runner. Restore the dependency, or remove the '
                  'codegen step if this package migrated to manual providers.'
            : 'pubspec.yaml declares build_runner but the CI workflow has no '
                  'codegen step to run it — add the step or drop the dependency.',
      );
    });
  });
}

/// Walks up from the test's working directory to the package root (the
/// directory holding pubspec.yaml). `flutter test` runs from the package
/// root, but this stays correct if invoked from a subdirectory.
Directory _repoRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      return Directory.current; // give up; the test will surface the problem
    }
    dir = parent;
  }
  return dir;
}
