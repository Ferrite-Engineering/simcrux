// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/riscv_formal_verdict.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/sby_outcome.dart';

// The committed demo corpus, guarded so it cannot silently rot
// (VERIFICATION_GUIDE.md §18.3).
//
// Two jobs:
//
//  1. **The required case list is asserted by name**, so a case cannot
//     quietly disappear and narrow the driver's coverage.
//  2. **`expected.json` is re-derived here** from the committed log by the
//     production parser, so a regression in the parser or in the
//     verdict→status mapping shows up as a failure rather than as a stale
//     golden that still agrees with itself.
//
// Regenerate with `dart run tool/generate_riscv_formal_fixtures.dart`.

const String _corpus = 'verification/fixtures/riscv_formal';

/// The §18.3 case list. Adding a case is fine; removing one is a decision.
const List<String> _required = <String>[
  'insn_add_pass',
  'insn_sub_counterexample',
  'pc_fwd_unknown',
  'reg_timeout',
  'causal_error',
  'liveness_no_outcome',
  'cover_multi_trace',
];

void main() {
  List<Directory> caseDirs() =>
      Directory(_corpus).listSync().whereType<Directory>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  Map<String, Object?> readJson(String path) =>
      jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;

  test('every required case is present', () {
    final present = caseDirs().map((d) => p.basename(d.path)).toList();
    expect(present, containsAll(_required));
  });

  test('every case has a manifest, a log and a golden', () {
    for (final dir in caseDirs()) {
      final name = p.basename(dir.path);
      expect(
        File(p.join(dir.path, 'case.json')).existsSync(),
        isTrue,
        reason: name,
      );
      expect(
        File(p.join(dir.path, 'expected.json')).existsSync(),
        isTrue,
        reason: name,
      );
      final decl = readJson(p.join(dir.path, 'case.json'));
      expect(
        File(p.join(dir.path, decl['log']! as String)).existsSync(),
        isTrue,
        reason: '$name: the log it declares',
      );
    }
  });

  test('every declared trace file is committed', () {
    // Demo mode stages these into the task directory, and the driver then
    // resolves them exactly as it resolves a real run's. A declared trace
    // that is not in the repo would make the WaveCrux hand-off test pass
    // for the wrong reason.
    for (final dir in caseDirs()) {
      final decl = readJson(p.join(dir.path, 'case.json'));
      for (final trace in (decl['traces']! as List).cast<String>()) {
        expect(
          File(p.join(dir.path, trace)).existsSync(),
          isTrue,
          reason: '${p.basename(dir.path)}: $trace',
        );
      }
    }
  });

  test('expected.json still matches what the real parser produces', () {
    for (final dir in caseDirs()) {
      final name = p.basename(dir.path);
      final decl = readJson(p.join(dir.path, 'case.json'));
      final golden = readJson(p.join(dir.path, 'expected.json'));
      final log = File(p.join(dir.path, decl['log']! as String));
      // Asserted, not defaulted. Substituting '' for a missing log makes
      // every case parse to NO_OUTCOME — a real verdict the parser can
      // legitimately produce — so the corpus going missing would read as a
      // parser regression instead of as the absent file it is.
      expect(
        log.existsSync(),
        isTrue,
        reason: '$name: ${decl['log']} is not on disk (is it committed?)',
      );
      final outcome = SbyLogReader.parse(log.readAsStringSync());
      expect(outcome.verdict.wireName, golden['verdict'], reason: name);
      expect(outcome.verdict.status.name, golden['status'], reason: name);
      expect(outcome.returnCode, golden['return_code'], reason: name);
      expect(outcome.depthReached, golden['depth_reached'], reason: name);
      expect(outcome.engine, golden['engine'], reason: name);
      expect(
        outcome.elapsedSeconds,
        golden['elapsed_seconds'],
        reason: name,
      );
      expect(outcome.traces, golden['traces'], reason: name);
    }
  });

  test('no case is ever unknown or vacuous', () {
    for (final dir in caseDirs()) {
      final status = readJson(p.join(dir.path, 'expected.json'))['status'];
      expect(
        status,
        anyOf('pass', 'fail'),
        reason: p.basename(dir.path),
      );
    }
  });

  test('the corpus covers every verdict the driver can report', () {
    // If a verdict has no fixture, its status mapping is untested and a
    // regression in it would land silently.
    final covered = caseDirs()
        .map(
          (d) =>
              readJson(p.join(d.path, 'expected.json'))['verdict']! as String,
        )
        .toSet();
    for (final verdict in RiscvFormalVerdict.values) {
      expect(
        covered,
        contains(verdict.wireName),
        reason: 'no fixture exercises ${verdict.wireName}',
      );
    }
  });

  test('exactly one non-cover case may pass', () {
    // A corpus that drifted into all-passing would still be green while
    // testing nothing about the failure paths.
    final passing = caseDirs()
        .where(
          (d) => readJson(p.join(d.path, 'expected.json'))['status'] == 'pass',
        )
        .map((d) => p.basename(d.path))
        .toList();
    expect(passing, ['cover_multi_trace', 'insn_add_pass']);
  });

  test('the trap case really does exit 0', () {
    // `liveness_no_outcome` is only a trap if the process succeeded.
    expect(
      readJson(
        p.join(_corpus, 'liveness_no_outcome', 'case.json'),
      )['exit_code'],
      0,
    );
    expect(
      readJson(
        p.join(_corpus, 'liveness_no_outcome', 'expected.json'),
      )['status'],
      TestStatus.fail.name,
    );
  });

  test('nothing in the corpus is derived from an upstream project', () {
    // Hand-authored so no third-party attribution obligation is created —
    // the same call the signature corpus makes. The version banner in each trace is
    // the marker; the README states the rule.
    for (final dir in caseDirs()) {
      final decl = readJson(p.join(dir.path, 'case.json'));
      for (final trace in (decl['traces']! as List).cast<String>()) {
        expect(
          File(p.join(dir.path, trace)).readAsStringSync(),
          contains('SimCrux hand-authored'),
          reason: '${p.basename(dir.path)}: $trace',
        );
      }
    }
    expect(
      File(p.join(_corpus, 'README.md')).readAsStringSync(),
      contains('Hand-authored'),
    );
  });
}
