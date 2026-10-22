// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/formal_property_status.dart';
import 'package:simcrux/domain/enums/formal_verdict.dart';
import 'package:simcrux/domain/models/eqy_outcome.dart';
import 'package:simcrux/services/formal/eqy_workdir_reader.dart';

import '../../support/eqy_workdir_fixture.dart';
import '../../support/formal_fixture_checks.dart';

// The EQY work-directory reader and the run's agreement rule, on the
// committed corpus rebuilt into the layout eqy writes, and on hostile
// directories: names that would leave the work directory, symlinks out of
// it, files too large to read whole.

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('eqy_workdir_'));
  tearDown(() => root.deleteSync(recursive: true));

  const reader = EqyWorkdirReader();

  EqyWorkdirSnapshot readRun(String run) {
    final work = p.join(root.path, run);
    stageEqyWorkdir(run, work);
    final log = EqyLogReader();
    capturedEqyLog(run).forEach(log.addLine);
    return reader.read(
      work,
      log: log.outcome.partitions,
      strategyOrder: const ['sby'],
    );
  }

  group('the corpus', () {
    for (final run in kFormalEqyRuns) {
      test('$run: every partition as the hand expectation says', () {
        final snapshot = readRun(run);
        expect(snapshot.partitionListRead, isTrue);
        final want = kEqyPartitionExpectations[run]!;
        expect(snapshot.partitions.map((x) => x.name).toSet(), want.keys);
        for (final partition in snapshot.partitions) {
          final equivalent = want[partition.name]!;
          expect(
            partition.status,
            equivalent
                ? FormalPropertyStatus.proved
                : FormalPropertyStatus.counterexample,
            reason: '$run ${partition.name}',
          );
          expect(partition.strategy, 'sby');
          expect(partition.disagreement, isFalse);
          if (equivalent) {
            expect(partition.trace, isNull);
          } else {
            // The base-case counterexample, never the induction trace.
            expect(partition.trace, isNotNull, reason: partition.name);
            expect(p.basename(partition.trace!), 'trace.vcd');
            expect(
              p.isWithin(p.join(root.path, run), partition.trace!),
              isTrue,
            );
            expect(File(partition.trace!).existsSync(), isTrue);
          }
        }
      });
    }

    // The step each counterexample failed at, as each partition's own
    // SymbiYosys summary states it (read by hand from the captured
    // `strategies/<p>/sby/sby.log`: `failed assertion … step 1`). alu_fail's
    // alu.r summary names no step, so none is stated: the hand-off then
    // carries no coordinate rather than a guessed step 0.
    test('each counterexample keeps the step its summary stated', () {
      final fail = {
        for (final x in readRun('alu_fail').partitions) x.name: x,
      };
      expect(fail['alu.z']!.step, 1);
      expect(fail['alu.r']!.step, isNull);
      expect(fail['alu.r']!.trace, isNotNull);
      final fail2 = readRun('alu_fail2').partitions;
      expect(
        {for (final x in fail2) x.name: x.step},
        {'alu.y': 1, 'alu.z': 1},
      );
      final pass = readRun('alu_pass').partitions;
      expect(
        pass.where((x) => x.trace == null).every((x) => x.step == null),
        isTrue,
      );
    });

    test('summarySteps reads only a basecase trace followed by its step', () {
      final steps = EqyWorkdirReader.summarySteps(
        <String>[
          'SBY 1:00:00 [p] summary: counterexample trace [basecase]: p/engine_0/trace.vcd',
          'SBY 1:00:00 [p] summary:   failed assertion m.a at x.sv:1.1-1.2 step 3',
          'SBY 1:00:00 [p] summary: counterexample trace [induction]: p/engine_0/trace_induct.vcd',
          'SBY 1:00:00 [p] summary:   failed assertion m.a at x.sv:1.1-1.2',
        ].join('\n'),
      );
      expect(steps, {'p/engine_0/trace.vcd': 3});
    });

    test('the four acceptance verdicts', () {
      FormalVerdict verdict(String run) => EqyReconciliation.reconcile(
        taskVerdict: EqyLogReader.parse(
          capturedEqyLog(run).join('\n'),
        ).verdict,
        snapshot: readRun(run),
      ).verdict;
      // A false FAIL on a correct netlist is still a FAIL: the explanation
      // belongs to the partition explorer, never a quieter verdict.
      expect(verdict('alu_pass'), FormalVerdict.fail);
      expect(verdict('alu_pass2'), FormalVerdict.pass);
      expect(verdict('alu_fail'), FormalVerdict.fail);
      expect(verdict('alu_fail2'), FormalVerdict.fail);
      final fail2 = readRun('alu_fail2').partitions;
      expect(
        fail2.where((x) => x.status == FormalPropertyStatus.counterexample),
        hasLength(2),
        reason: 'the mutant fails 2 of 2 partitions',
      );
    });
  });

  group('the agreement rule', () {
    EqyWorkdirSnapshot snapshot(List<FormalVerdict> tokens) =>
        EqyWorkdirSnapshot(
          partitionListRead: true,
          partitions: [
            for (final (i, t) in tokens.indexed)
              EqyPartitionResult(
                name: 'm.p$i',
                status: switch (t) {
                  FormalVerdict.pass => FormalPropertyStatus.proved,
                  FormalVerdict.fail => FormalPropertyStatus.counterexample,
                  FormalVerdict.unknown ||
                  FormalVerdict.timeout => FormalPropertyStatus.inconclusive,
                  _ => FormalPropertyStatus.didNotRun,
                },
                token: t,
              ),
          ],
        );

    test('PASS stands only when every partition was proved', () {
      final all = EqyReconciliation.reconcile(
        taskVerdict: FormalVerdict.pass,
        snapshot: snapshot([FormalVerdict.pass, FormalVerdict.pass]),
      );
      expect(all.verdict, FormalVerdict.pass);
      expect(all.disagreement, isFalse);
      for (final worse in [
        FormalVerdict.fail,
        FormalVerdict.unknown,
        FormalVerdict.timeout,
        FormalVerdict.error,
        FormalVerdict.noOutcome,
      ]) {
        final r = EqyReconciliation.reconcile(
          taskVerdict: FormalVerdict.pass,
          snapshot: snapshot([FormalVerdict.pass, worse]),
        );
        expect(r.verdict, worse, reason: '$worse under a PASS');
        expect(r.disagreement, isTrue);
      }
    });

    test('a FAIL is never softened, and never becomes PASS', () {
      for (final partitions in [
        [FormalVerdict.pass, FormalVerdict.unknown],
        [FormalVerdict.pass, FormalVerdict.pass],
        [FormalVerdict.error],
      ]) {
        expect(
          EqyReconciliation.reconcile(
            taskVerdict: FormalVerdict.fail,
            snapshot: snapshot(partitions),
          ).verdict,
          FormalVerdict.fail,
          reason: '$partitions',
        );
      }
    });

    test('a run that wrote no partition list cannot pass', () {
      final r = EqyReconciliation.reconcile(
        taskVerdict: FormalVerdict.pass,
        snapshot: const EqyWorkdirSnapshot(partitionListRead: false),
      );
      expect(r.verdict, FormalVerdict.noOutcome);
      expect(r.disagreement, isTrue);
      expect(
        EqyReconciliation.reconcile(
          taskVerdict: FormalVerdict.error,
          snapshot: const EqyWorkdirSnapshot(partitionListRead: false),
        ).verdict,
        FormalVerdict.error,
      );
    });

    test('a killed run with some partitions proved is no outcome', () {
      expect(
        EqyReconciliation.reconcile(
          taskVerdict: FormalVerdict.noOutcome,
          snapshot: snapshot([FormalVerdict.pass]),
        ).verdict,
        FormalVerdict.noOutcome,
      );
    });
  });

  group('status file against the log', () {
    late String work;
    setUp(() {
      work = p.join(root.path, 'w');
      Directory(p.join(work, 'strategies', 'm.a', 's')).createSync(
        recursive: true,
      );
      File(p.join(work, 'partition.list')).writeAsStringSync(
        'm m.a : a[0]\nm m.b : b[0]\n',
      );
      File(
        p.join(work, 'summary_targets.list'),
      ).writeAsStringSync('strategies/m.a/s/status\nstrategies/m.b/s/status\n');
    });

    void status(String partition, String text) {
      Directory(
        p.join(work, 'strategies', partition, 's'),
      ).createSync(recursive: true);
      File(
        p.join(work, 'strategies', partition, 's', 'status'),
      ).writeAsStringSync(text);
    }

    test('a partition with no status file did not run, whatever the log', () {
      status('m.a', 'PASS\n');
      final snap = reader.read(
        work,
        log: const {'m.b': EqyLogPartitionStatus.proved},
      );
      expect(snap.partitions[1].status, FormalPropertyStatus.didNotRun);
      expect(snap.partitions[1].disagreement, isTrue);
    });

    test('the status file and the log: the more conservative wins', () {
      status('m.a', 'PASS\n');
      status('m.b', 'UNKNOWN\n');
      final snap = reader.read(
        work,
        log: const {
          'm.a': EqyLogPartitionStatus.notEquivalent,
          'm.b': EqyLogPartitionStatus.failed,
        },
      );
      expect(snap.partitions[0].status, FormalPropertyStatus.counterexample);
      expect(snap.partitions[0].disagreement, isTrue);
      expect(snap.partitions[1].status, FormalPropertyStatus.inconclusive);
      expect(snap.partitions[1].disagreement, isFalse);
    });

    test('tokens: TIMEOUT, ERROR, cached, and a word EQY never writes', () {
      status('m.a', 'TIMEOUT\n');
      status('m.b', 'ERROR\n');
      var snap = reader.read(work);
      expect(snap.partitions[0].token, FormalVerdict.timeout);
      expect(snap.partitions[1].token, FormalVerdict.error);
      status('m.a', 'PASS (cached)\n');
      status('m.b', 'MAYBE\n');
      snap = reader.read(work);
      expect(snap.partitions[0].status, FormalPropertyStatus.proved);
      expect(snap.partitions[1].status, FormalPropertyStatus.didNotRun);
    });

    test('a cached FAIL finds the counterexample of the strategy that '
        'decided', () {
      status('m.a', 'FAIL (cached)\n');
      final first = p.join(work, 'strategies', 'm.a', 'quick');
      Directory(first).createSync(recursive: true);
      File(p.join(first, 'status')).writeAsStringSync('FAIL\n');
      File(p.join(first, 'trace.vcd')).writeAsStringSync(r'$date x $end');
      final snap = reader.read(work, strategyOrder: const ['quick', 's']);
      expect(snap.partitions[0].status, FormalPropertyStatus.counterexample);
      expect(snap.partitions[0].trace, p.join(first, 'trace.vcd'));
    });
  });

  group('containment', () {
    late String work;
    setUp(() {
      work = p.join(root.path, 'w');
      Directory(work).createSync();
    });

    for (final name in const [
      '../escape',
      '/etc',
      r'C:\x',
      'a/b',
      r'a\b',
      'c:d',
      '..',
    ]) {
      test('a partition named "$name" is never joined into a path', () {
        File(
          p.join(work, 'partition.list'),
        ).writeAsStringSync('m $name : o\n');
        File(
          p.join(work, 'summary_targets.list'),
        ).writeAsStringSync('strategies/$name/s/status\n');
        final snap = reader.read(work);
        final partition = snap.partitions.single;
        expect(partition.status, FormalPropertyStatus.didNotRun);
        expect(partition.trace, isNull);
        expect(partition.note, isNotNull);
        expect(snap.notes, isNotEmpty);
      });
    }

    test('a summary target that walks out is skipped', () {
      File(p.join(work, 'partition.list')).writeAsStringSync('m m.a : o\n');
      File(
        p.join(work, 'summary_targets.list'),
      ).writeAsStringSync('strategies/m.a/../../../status\n');
      final snap = reader.read(work);
      expect(snap.partitions.single.status, FormalPropertyStatus.didNotRun);
      expect(snap.partitions.single.strategy, isNull);
    });

    test('a status file symlinked out of the work directory is not read', () {
      final outside = File(p.join(root.path, 'outside_status'))
        ..writeAsStringSync('PASS\n');
      Directory(
        p.join(work, 'strategies', 'm.a', 's'),
      ).createSync(recursive: true);
      Link(
        p.join(work, 'strategies', 'm.a', 's', 'status'),
      ).createSync(outside.path);
      File(p.join(work, 'partition.list')).writeAsStringSync('m m.a : o\n');
      File(
        p.join(work, 'summary_targets.list'),
      ).writeAsStringSync('strategies/m.a/s/status\n');
      final snap = reader.read(work);
      expect(snap.partitions.single.status, FormalPropertyStatus.didNotRun);
    }, skip: Platform.isWindows ? 'symlinks need privileges' : false);

    test('a trace that resolves outside is not attached', () {
      final outside = File(p.join(root.path, 'evil.vcd'))
        ..writeAsStringSync('x');
      final dir = p.join(work, 'strategies', 'm.a', 's');
      Directory(p.join(dir, 'm.a')).createSync(recursive: true);
      File(p.join(dir, 'status')).writeAsStringSync('FAIL\n');
      File(p.join(dir, 'm.a', 'logfile.txt')).writeAsStringSync(
        'SBY 1 [m.a] summary: counterexample trace [basecase]: '
        '../../../../../evil.vcd\n'
        'SBY 1 [m.a] summary: counterexample trace [basecase]: '
        '${outside.path}\n',
      );
      File(p.join(work, 'partition.list')).writeAsStringSync('m m.a : o\n');
      File(
        p.join(work, 'summary_targets.list'),
      ).writeAsStringSync('strategies/m.a/s/status\n');
      final partition = reader.read(work).partitions.single;
      expect(partition.status, FormalPropertyStatus.counterexample);
      expect(partition.trace, isNull);
    });

    test('an induction trace alone is never the counterexample', () {
      final dir = p.join(work, 'strategies', 'm.a', 's');
      Directory(p.join(dir, 'm.a', 'engine_0')).createSync(recursive: true);
      File(p.join(dir, 'status')).writeAsStringSync('FAIL\n');
      File(
        p.join(dir, 'm.a', 'engine_0', 'trace_induct.vcd'),
      ).writeAsStringSync('x');
      File(p.join(dir, 'm.a', 'logfile.txt')).writeAsStringSync(
        'SBY 1 [m.a] summary: counterexample trace [induction]: '
        'm.a/engine_0/trace_induct.vcd\n',
      );
      File(p.join(work, 'partition.list')).writeAsStringSync('m m.a : o\n');
      File(
        p.join(work, 'summary_targets.list'),
      ).writeAsStringSync('strategies/m.a/s/status\n');
      expect(reader.read(work).partitions.single.trace, isNull);
    });
  });

  group('bounds', () {
    test('no partition.list: nothing was partitioned', () {
      final snap = reader.read(root.path);
      expect(snap.partitionListRead, isFalse);
      expect(snap.partitions, isEmpty);
    });

    test('more partitions than SimCrux reads are counted as truncated', () {
      final work = p.join(root.path, 'big');
      Directory(work).createSync();
      final lines = StringBuffer();
      for (var i = 0; i < EqyWorkdirReader.kMaxPartitions + 5; i++) {
        lines.writeln('m m.p$i : o[$i]');
      }
      File(p.join(work, 'partition.list')).writeAsStringSync('$lines');
      final snap = reader.read(work);
      expect(snap.partitions, hasLength(EqyWorkdirReader.kMaxPartitions));
      expect(snap.truncated, isTrue);
      expect(snap.notes.first, contains('partition.list'));
    });
  });
}
