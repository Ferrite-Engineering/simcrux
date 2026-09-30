// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/services/config/config_loader.dart';

/// Every orchestration scenario carries the full companion set: a
/// `simcrux.yaml` (the input config), a `behaviors.json` (the fake-runner
/// script), and a golden (`expected_results.ndjson` or `expected_*.json`).
/// A `behaviors.json` without a `simcrux.yaml`, or a scenario missing its
/// golden, is a corpus defect the next contributor cannot ship past.
///
/// The companion set is checked for **presence and validity**. Presence
/// alone is not a guard: the corpus once shipped three `simcrux.yaml`
/// files written against a schema [ConfigLoader] rejects outright
/// (`Missing required field \`version\``), and every existence check in
/// the suite was green the whole time — including the release-sign-off
/// mirror under `verification/`, which is the copy a human opens in the
/// app. So each committed `simcrux.yaml` is also parsed here through the
/// real loader, the same code path the app uses on File → Open Project.
void main() {
  const corpora = <String>[
    'test/fixtures/orchestration',
    'verification/fixtures/orchestration',
  ];

  for (final corpus in corpora) {
    test('$corpus: each generated/ has yaml + behaviors + a golden', () {
      final root = Directory(corpus);
      if (!root.existsSync()) return;

      // Collect every scenario's generated/ directory.
      final generatedDirs = <Directory>[];
      for (final entity in root.listSync(recursive: true)) {
        if (entity is Directory && p.basename(entity.path) == 'generated') {
          generatedDirs.add(entity);
        }
      }
      expect(
        generatedDirs,
        isNotEmpty,
        reason: 'no scenarios committed under $corpus',
      );

      for (final dir in generatedDirs) {
        final files = dir
            .listSync()
            .whereType<File>()
            .map((f) => p.basename(f.path))
            .toSet();
        final scenario = p.basename(p.dirname(dir.path));

        expect(
          files,
          contains('simcrux.yaml'),
          reason: '$scenario: missing simcrux.yaml',
        );
        expect(
          files,
          contains('behaviors.json'),
          reason: '$scenario: behaviors.json has no companion config',
        );
        final hasGolden = files.any(
          (f) =>
              f.startsWith('expected_') &&
              (f.endsWith('.ndjson') || f.endsWith('.json')),
        );
        expect(
          hasGolden,
          isTrue,
          reason: '$scenario: missing an expected_* golden',
        );
      }
    });

    test('$corpus: every committed simcrux.yaml loads through '
        'ConfigLoader', () async {
      final root = Directory(corpus);
      if (!root.existsSync()) return;

      final configs = root
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => p.basename(f.path) == 'simcrux.yaml')
          .toList();
      expect(configs, isNotEmpty, reason: 'no configs committed under $corpus');

      for (final file in configs) {
        // Deliberately unguarded: a ConfigLoaderException here IS the
        // failure, and its message already carries `file:line:col`.
        final config = await ConfigLoader().load(file.path);
        expect(
          config.suites,
          isNotEmpty,
          reason: '${file.path}: loaded with no suites',
        );
        expect(
          config.suites.expand((s) => s.tests),
          isNotEmpty,
          reason: '${file.path}: loaded with no tests',
        );
      }
    });
  }
}
