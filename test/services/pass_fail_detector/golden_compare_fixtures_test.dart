// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/golden_compare_profile.dart';
import 'package:simcrux/domain/models/golden_comparator.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/services/pass_fail_detector/golden_compare_detector.dart';

// Guard for the committed `golden_compare` fixture corpus. Replays every
// case directory through the real detector and the real comparator and
// diffs against the committed `expected.json`, so the fixtures cannot
// silently rot and a comparator regression cannot slip past as "the
// fixture must be stale".
//
// Regenerate the goldens with:
//   dart run tool/generate_golden_compare_fixtures.dart
//
// The corpus is also the required case list, which is asserted
// here by name — a deleted case fails this test rather than quietly
// reducing coverage.
void main() {
  const fixtureRoot = 'verification/fixtures/golden_compare';
  const detector = GoldenCompareDetector();

  // Every required case, plus the profile-observability pair.
  const requiredCases = <String>{
    'clean_pass',
    'first_word_mismatch',
    'mid_file_mismatch',
    'length_mismatch',
    'empty_dut',
    'missing_dut',
    'format_variance_riscv',
    'format_variance_generic',
  };

  late List<Directory> cases;

  setUpAll(() {
    final root = Directory(fixtureRoot);
    expect(
      root.existsSync(),
      isTrue,
      reason: 'run from the package root (cwd = simcrux/)',
    );
    cases = root.listSync().whereType<Directory>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  });

  test('every required fixture case is present', () {
    final names = cases.map((d) => d.path.split(Platform.pathSeparator).last);
    expect(names, containsAll(requiredCases));
  });

  test('at least one case reports pass and at least one reports fail', () {
    // A corpus that only ever fails would pass a detector hard-wired to
    // TestStatus.fail; one that only ever passes would miss the exit-0 trap.
    final statuses = <String>{};
    for (final dir in cases) {
      final expected =
          jsonDecode(File('${dir.path}/expected.json').readAsStringSync())
              as Map<String, Object?>;
      statuses.add(expected['status']! as String);
    }
    expect(statuses, containsAll(<String>['pass', 'fail']));
  });

  test('fixture cases replay to their committed goldens', () async {
    for (final dir in cases) {
      final name = dir.path.split(Platform.pathSeparator).last;
      final decl =
          jsonDecode(File('${dir.path}/case.json').readAsStringSync())
              as Map<String, Object?>;
      final expected =
          jsonDecode(File('${dir.path}/expected.json').readAsStringSync())
              as Map<String, Object?>;

      final profile = GoldenCompareProfile.fromWireName(decl['profile']);
      expect(profile, isNotNull, reason: '$name: unknown profile');
      final dutName = decl['dut']! as String;
      final refName = decl['reference']! as String;

      final status = await detector.detectAsync(
        stdout: '',
        stderr: '',
        exitCode: 0,
        runtime: Duration.zero,
        config: GoldenComparePassFailConfig(
          dutPath: dutName,
          referencePath: refName,
          profile: profile!,
        ),
        workingDirectory: dir.path,
      );
      expect(status.name, expected['status'], reason: '$name: verdict');

      final dutFile = File('${dir.path}/$dutName');
      expect(
        dutFile.existsSync(),
        expected['dut_present'],
        reason: '$name: DUT file presence drifted from the golden',
      );
      if (!dutFile.existsSync()) {
        expect(expected['comparison'], isNull, reason: name);
        expect(expected['metrics'], isNull, reason: name);
        continue;
      }

      final result = GoldenComparator.compare(
        dut: dutFile.readAsStringSync(),
        reference: File('${dir.path}/$refName').readAsStringSync(),
        profile: profile,
      );
      final comparison = expected['comparison']! as Map<String, Object?>;
      expect(result.matched, comparison['matched'], reason: '$name: matched');
      expect(
        result.mismatchOffset,
        comparison['mismatch_offset'],
        reason: '$name: offset',
      );
      expect(result.dutWord, comparison['dut_value'], reason: '$name: dut');
      expect(result.refWord, comparison['ref_value'], reason: '$name: ref');
      expect(result.dutWords, comparison['dut_words'], reason: '$name: n_dut');
      expect(result.refWords, comparison['ref_words'], reason: '$name: n_ref');
      expect(
        result.toMetrics(),
        expected['metrics'],
        reason: '$name: driver metrics',
      );
    }
  });

  test('the required boundary cases assert the values that matter', () async {
    Map<String, Object?> golden(String name) =>
        jsonDecode(File('$fixtureRoot/$name/expected.json').readAsStringSync())
            as Map<String, Object?>;

    // Offset 0 — the boundary an off-by-one hides.
    final first =
        golden('first_word_mismatch')['comparison']! as Map<String, Object?>;
    expect(first['mismatch_offset'], 0);

    // Mid-file — proves the scan does not stop at the first word.
    final mid =
        golden('mid_file_mismatch')['comparison']! as Map<String, Object?>;
    expect(mid['mismatch_offset'], 3);

    // Length divergence — only the longer side carries a word.
    final len =
        golden('length_mismatch')['comparison']! as Map<String, Object?>;
    expect(len['dut_value'], isNull);
    expect(len['ref_value'], isNotNull);
    expect(len['dut_words'], isNot(len['ref_words']));

    // Empty and missing are failures.
    expect(golden('empty_dut')['status'], 'fail');
    expect(golden('missing_dut')['status'], 'fail');
    expect(golden('missing_dut')['dut_present'], isFalse);

    // The profile is observable: byte-identical inputs, opposite verdicts.
    expect(golden('format_variance_riscv')['status'], 'pass');
    expect(golden('format_variance_generic')['status'], 'fail');
    final riscvDut = File(
      '$fixtureRoot/format_variance_riscv/dut.sig',
    ).readAsBytesSync();
    final genericDut = File(
      '$fixtureRoot/format_variance_generic/dut.sig',
    ).readAsBytesSync();
    expect(riscvDut, genericDut, reason: 'the pair must share its inputs');
  });
}
