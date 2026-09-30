// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Regenerates the `expected.json` golden for every `golden_compare`
// fixture case.
//
//   dart run tool/generate_golden_compare_fixtures.dart
//
// Each case directory under `verification/fixtures/golden_compare/`
// holds:
//
//   case.json     — the input declaration (description, profile, and the
//                   two filenames). Hand-written; never regenerated.
//   <dut file>    — the DUT dump. ABSENT in the missing-dut case.
//   <golden file> — the golden reference dump.
//   expected.json — the golden this script writes: the verdict the real
//                   GoldenCompareDetector produces, the full
//                   GoldenComparison, and the `golden.*` metrics a driver
//                   would emit for it.
//
// The verdict is produced by running the **real** detector against the
// **real** files — not by restating what the fixture author expected — so
// a regression in the comparator or in the detector's status mapping
// shows up as a diff here and in
// `test/services/pass_fail_detector/golden_compare_fixtures_test.dart`.
import 'dart:convert';
import 'dart:io';

import 'package:simcrux/domain/enums/golden_compare_profile.dart';
import 'package:simcrux/domain/models/golden_comparator.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/services/pass_fail_detector/golden_compare_detector.dart';

const String fixtureRoot = 'verification/fixtures/golden_compare';

Future<void> main() async {
  final root = Directory(fixtureRoot);
  if (!root.existsSync()) {
    stderr.writeln(
      'Run from the package root (cwd = simcrux/); $fixtureRoot not found.',
    );
    exitCode = 1;
    return;
  }

  final cases = root.listSync().whereType<Directory>().toList(growable: false)
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final dir in cases) {
    final expected = await buildExpected(dir);
    final out = File('${dir.path}/expected.json');
    out.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(expected)}\n',
    );
    stdout.writeln('wrote ${out.path}  → ${expected['status']}');
  }
}

/// Computes the expected record for one fixture case directory by running
/// the production detector and comparator against its files.
Future<Map<String, Object?>> buildExpected(Directory dir) async {
  final decl =
      jsonDecode(File('${dir.path}/case.json').readAsStringSync())
          as Map<String, Object?>;
  final profile = GoldenCompareProfile.fromWireName(decl['profile']);
  if (profile == null) {
    throw StateError(
      '${dir.path}/case.json: unknown profile ${decl['profile']}',
    );
  }
  final dutName = decl['dut']! as String;
  final refName = decl['reference']! as String;

  final config = GoldenComparePassFailConfig(
    dutPath: dutName,
    referencePath: refName,
    profile: profile,
  );
  const detector = GoldenCompareDetector();
  final status = await detector.detectAsync(
    stdout: '',
    stderr: '',
    exitCode: 0,
    runtime: Duration.zero,
    config: config,
    workingDirectory: dir.path,
  );

  final dutFile = File('${dir.path}/$dutName');
  final refFile = File('${dir.path}/$refName');
  Map<String, Object?>? comparison;
  Map<String, String>? metrics;
  if (dutFile.existsSync() && refFile.existsSync()) {
    final result = GoldenComparator.compare(
      dut: dutFile.readAsStringSync(),
      reference: refFile.readAsStringSync(),
      profile: profile,
    );
    comparison = <String, Object?>{
      'matched': result.matched,
      'mismatch_offset': result.mismatchOffset,
      'dut_value': result.dutWord,
      'ref_value': result.refWord,
      'dut_words': result.dutWords,
      'ref_words': result.refWords,
    };
    metrics = result.toMetrics();
  }

  return <String, Object?>{
    'description': decl['description'],
    'profile': profile.wireName,
    'dut': dutName,
    'dut_present': dutFile.existsSync(),
    'reference': refName,
    'status': status.name,
    'comparison': comparison,
    'metrics': metrics,
  };
}
