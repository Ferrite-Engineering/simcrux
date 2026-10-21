// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/sby_outcome.dart';
import 'package:simcrux/services/formal/formal_reconciliation.dart';
import 'package:simcrux/services/formal/sby_status_database.dart';
import 'package:simcrux/services/formal/sby_status_reader.dart';

import '../../support/formal_fixture_checks.dart';
import '../../support/formal_reader_checks.dart';

// Every hand-written expectation of the committed formal corpus, reproduced
// by the product's readers: the log reader, the status stream reader,
// status.sqlite and the agreement rule. The expectations come from the
// property's meaning and the RTL (PROVENANCE.md); this test never derives
// one from our output. A missing case or capture fails by name.

void main() {
  String root() => p.absolute(kFormalFixtureRoot);

  for (final name in kFormalSbyCases) {
    group(name, () {
      late Map<String, Object?> expected;
      late String captured;

      setUpAll(() {
        final dir = p.join(root(), 'sby', name);
        expect(Directory(dir).existsSync(), isTrue, reason: dir);
        expected = readJsonObject(p.join(dir, '$name.expected.json'));
        captured = p.join(dir, 'captured');
        expect(Directory(captured).existsSync(), isTrue, reason: captured);
      });

      for (final source in const ['stream and status.sqlite', 'stream only']) {
        test('every task agrees with its expectation ($source)', () async {
          final tasks = expected['tasks']! as Map<String, Object?>;
          expect(tasks, isNotEmpty);
          final problems = <String>[];
          for (final MapEntry(key: task, value: spec) in tasks.entries) {
            final taskDir = p.join(captured, task);
            final log = File(p.join(taskDir, 'sby.log'));
            expect(log.existsSync(), isTrue, reason: log.path);
            final text = log.readAsStringSync();
            final database = source == 'stream only'
                ? null
                : await SbyStatusDatabase.read(
                    p.join(captured, 'status.sqlite'),
                    task: task,
                  );
            if (source != 'stream only') {
              expect(database, isNotNull, reason: '$name status.sqlite');
            }
            final reconciliation = FormalReconciliation.reconcile(
              taskVerdict: SbyLogReader.parse(text).verdict,
              proofMode: null,
              live: SbyStatusReader.parse(text, task: task),
              database: database,
            );
            problems.addAll(
              checkReportedTask(
                task: task,
                spec: spec! as Map<String, Object?>,
                verdict: reconciliation.verdict.wireName,
                properties: reportedFromReconciliation(reconciliation),
                taskDirectory: taskDir,
              ),
            );
            // The corpus is self-consistent: nothing in it disagrees.
            if (reconciliation.disagreement ?? false) {
              problems.add('$task: unexpected disagreement');
            }
          }
          expect(problems, isEmpty, reason: problems.join('\n'));
        });
      }
    });
  }

  test('an induction FAIL is never a counterexample', () {
    // handshake_imm prove_bug: the stream carries the induction failure of
    // line 45 (trace_induct, no depth) beside the base-case one.
    final text = File(
      p.join(
        root(),
        'sby',
        'handshake_imm',
        'captured',
        'prove_bug',
        'sby.log',
      ),
    ).readAsStringSync();
    final live = SbyStatusReader.parse(text, task: 'prove_bug');
    final fold = live.properties.singleWhere(
      (f) => f.location.startsWith('handshake_imm.sv:45.'),
    );
    expect(fold.inductionFailed, isTrue);
    expect(fold.step, 6);
    expect(fold.trace, isNot(contains('trace_induct')));
    expect(SbyLogReader.parse(text).traces, [
      'handshake_imm_prove_bug/engine_0/trace.vcd',
    ]);
  });
}
