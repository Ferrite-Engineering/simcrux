// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/formal_verdict.dart';
import 'package:simcrux/domain/models/eqy_outcome.dart';
import 'package:simcrux/services/import/eqy_project_importer.dart';

import '../../support/eqy_workdir_fixture.dart';
import '../../support/formal_fixture_checks.dart';

void main() {
  group('the committed EQY logs', () {
    final expected = readJsonObject(
      '$kFormalFixtureRoot/eqy/eqy.expected.json',
    );
    final runs = expected['runs']! as Map<String, Object?>;

    for (final run in kFormalEqyRuns) {
      test('$run: the DONE token and every partition, as expected', () {
        final reader = EqyLogReader();
        capturedEqyLog(run).forEach(reader.addLine);
        final outcome = reader.outcome;
        final spec = runs[run]! as Map<String, Object?>;
        expect(outcome.verdict.wireName, spec['verdict']);
        expect(outcome.returnCode, spec['verdict'] == 'PASS' ? 0 : 2);
        expect(outcome.designsEquivalent, spec['verdict'] == 'PASS');
        final want = kEqyPartitionExpectations[run]!;
        expect(outcome.partitions.keys.toSet(), want.keys.toSet());
        for (final MapEntry(:key, :value) in want.entries) {
          expect(
            outcome.partitions[key],
            value
                ? EqyLogPartitionStatus.proved
                : EqyLogPartitionStatus.notEquivalent,
            reason: '$run $key',
          );
        }
        expect(outcome.elapsedSeconds, isNotNull);
      });
    }

    test('the hand expectations agree with eqy.expected.json', () {
      for (final run in kFormalEqyRuns) {
        final spec = runs[run]! as Map<String, Object?>;
        final failing = <String>{
          for (final MapEntry(:key, :value)
              in kEqyPartitionExpectations[run]!.entries)
            if (!value) key.split('.').last,
        };
        final listed = (spec['failing_outputs'] as List<Object?>? ?? const [])
            .cast<String>()
            .toSet();
        expect(failing, listed, reason: run);
      }
    });
  });

  group('reading lines', () {
    test('the prefix is stripped whatever the work directory is', () {
      final outcome = EqyLogReader.parse(
        'EQY 18:06:21 [/tmp/x [1]/alu] DONE (PASS, rc=0)\n',
      );
      expect(outcome.verdict, FormalVerdict.pass);
    });

    test('no DONE line is NO_OUTCOME, never a pass', () {
      final outcome = EqyLogReader.parse(
        "EQY 1 [a] run: Proved equivalence of partition 'm.x' using "
        "strategy 'sby'\n",
      );
      expect(outcome.verdict, FormalVerdict.noOutcome);
      expect(outcome.partitions['m.x'], EqyLogPartitionStatus.proved);
    });

    test('an unrecognised token is an error with the line kept', () {
      final outcome = EqyLogReader.parse('EQY 1 [a] DONE (MAYBE, rc=9)\n');
      expect(outcome.verdict, FormalVerdict.error);
      expect(outcome.errorLine, contains('MAYBE'));
    });

    test('a PASS never replaces an earlier non-PASS', () {
      final outcome = EqyLogReader.parse(
        'EQY 1 [a] DONE (FAIL, rc=2)\nEQY 1 [a] DONE (PASS, rc=0)\n',
      );
      expect(outcome.verdict, FormalVerdict.fail);
    });

    test('each strategy reason maps to its own status', () {
      const head = 'EQY 1 [a] run: Could not prove equivalence of partition';
      final outcome = EqyLogReader.parse(
        "$head 'p.u' using strategy 's': equivalence unknown\n"
        "$head 'p.t' using strategy 's': timeout\n"
        "EQY 1 [a] run: Execution of strategy 's' on partition 'p.e' "
        'encountered an error.\n',
      );
      expect(outcome.partitions, {
        'p.u': EqyLogPartitionStatus.unknown,
        'p.t': EqyLogPartitionStatus.timeout,
        'p.e': EqyLogPartitionStatus.error,
      });
    });

    test(
      'a later strategy decides; the summary never upgrades a partition',
      () {
        final outcome = EqyLogReader.parse(
          "EQY 1 [a] run: Could not prove equivalence of partition 'p.a' "
          "using strategy 'sat': equivalence unknown\n"
          "EQY 1 [a] run: Proved equivalence of partition 'p.a' using "
          "strategy 'sby'\n"
          "EQY 1 [a] run: Could not prove equivalence of partition 'p.b' "
          "using strategy 'sat': equivalence unknown\n"
          'EQY 1 [a] Successfully proved equivalence of partition p.b\n'
          'EQY 1 [a] Failed to prove equivalence of partition p.a\n',
        );
        expect(outcome.partitions['p.b'], EqyLogPartitionStatus.unknown);
        expect(outcome.partitions['p.a'], EqyLogPartitionStatus.failed);
      },
    );
  });

  test('the importer keys its detector on the same marker', () {
    expect(EqyLogReader.kPassMarker, 'DONE (PASS');
    final yaml = EqyProjectImporter(
      fileExists: (_) => true,
      readFile: (_) => '[gold]\nread_verilog a.v\n[gate]\nread_verilog b.v\n',
    ).importFile(path: '/p/x.eqy', outputDirectory: '/p').simcruxYaml;
    expect(yaml, contains("pass_string: '${EqyLogReader.kPassMarker}'"));
  });
}
