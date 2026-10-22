// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Run directories are precious and never deleted. No Flow code path calls
/// a delete, and none passes LibreLane `--overwrite` or `--last-run` (the
/// two options with which LibreLane deletes or resumes a run SimCrux did
/// not create).
///
/// Scans code, not comments: the drivers' documentation names both options
/// to say they are never passed.
void main() {
  final files = <File>[
    ...Directory('lib/services/flow')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart')),
    ...Directory('lib/core/cli').listSync().whereType<File>().where(
      (f) => p.basename(f.path).startsWith('flow_'),
    ),
  ];

  test('the scan sees the Flow code', () {
    final names = files.map((f) => p.basename(f.path)).toSet();
    expect(
      names,
      containsAll(<String>[
        'librelane_flow_driver.dart',
        'nextpnr_flow_driver.dart',
        'flow_run_ingestor.dart',
        'flow_handoff_launcher.dart',
        'flow_cli.dart',
      ]),
    );
  });

  test('no Flow code path deletes a file or a directory', () {
    final delete = RegExp(r'\.(delete|deleteSync)\s*\(');
    final offenders = <String>[];
    for (final file in files) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trimLeft();
        if (line.startsWith('//')) continue;
        if (delete.hasMatch(line)) offenders.add('${file.path}:${i + 1}');
      }
    }
    expect(offenders, isEmpty);
  });

  test('no Flow code passes --overwrite or --last-run', () {
    final offenders = <String>[];
    for (final file in files) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trimLeft();
        if (line.startsWith('//')) continue;
        if (line.contains("'--overwrite'") || line.contains("'--last-run'")) {
          offenders.add('${file.path}:${i + 1}');
        }
      }
    }
    expect(offenders, isEmpty);
  });
}
