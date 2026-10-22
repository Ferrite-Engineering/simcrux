// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// PretraceDetector on the designs sby elaborated for the corpus
// (`captured/<task>/elaborated.json`, Yosys JSON of `model/design.il`): the
// `$past` depth feeding each formal cell, against the hand expectations
// (`pretrace.past_depth` in fifo_slang and pretrace), on both frontends.
// A design register (the FIFO count, the step counter) is never counted.
//
// MUTATION: count every flip-flop as a `$past` register and fifo_slang's
// a_never_over (count <= D, no `$past`) gets a depth; stop following the
// chain through D and c_drain's depth drops from 4 to 1.

import 'dart:io';

import 'package:crux_netlist/crux_netlist.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/services/formal/pretrace_detector.dart';

import '../../support/formal_fixture_checks.dart';

FormalDesignFacts _facts(String caseName, String task) {
  final file = File(
    p.join(
      kFormalFixtureRoot,
      'sby',
      caseName,
      'captured',
      task,
      'elaborated.json',
    ),
  );
  if (!file.existsSync()) fail('${file.path} is missing');
  return const PretraceDetector().analyse(
    const YosysJsonParser().parse(file.readAsStringSync()),
  );
}

/// The exposure of the cell on [line] of [file].
FormalCellExposure _onLine(FormalDesignFacts facts, String file, int line) {
  final hit = facts.cells.where(
    (c) => c.location.startsWith('$file:$line.'),
  );
  if (hit.isEmpty) fail('no formal cell on $file:$line in ${facts.cells}');
  return hit.single;
}

void main() {
  group('fifo_slang (yosys-slang)', () {
    final expected = readJsonObject(
      p.join(kFormalFixtureRoot, 'sby/fifo_slang/fifo_slang.expected.json'),
    );
    final cov =
        (expected['tasks']! as Map<String, Object?>)['cov']!
            as Map<String, Object?>;

    test(r'c_drain reads $past(full, 4): depth 4, the hand expectation', () {
      final facts = _facts('fifo_slang', 'cov');
      for (final prop in objectList(cov['properties'])) {
        final want =
            (prop['pretrace'] as Map<String, Object?>?)?['past_depth'] ?? 0;
        expect(
          _onLine(facts, 'fifo_slang.sv', prop['line']! as int).pastDepth,
          want,
          reason: 'line ${prop['line']}',
        );
      }
    });

    test(r'one-deep $past and $rose count 1; design registers count 0', () {
      final facts = _facts('fifo_slang', 'ok');
      // a_never_over and a_full_empty read only design registers.
      expect(_onLine(facts, 'fifo_slang.sv', 38).pastDepth, 0);
      expect(_onLine(facts, 'fifo_slang.sv', 39).pastDepth, 0);
      // a_cnt_up: $past(...), $past(rst), $past(count); a_rose_full: $rose.
      expect(_onLine(facts, 'fifo_slang.sv', 40).pastDepth, 1);
      expect(_onLine(facts, 'fifo_slang.sv', 41).pastDepth, 1);
      expect(_onLine(facts, 'fifo_slang.sv', 42).pastDepth, 0);
    });

    // What each property reads, from the RTL (fifo_slang.sv): the names on
    // the combinational paths into the check, through `$past`, stopping at
    // the design's registers; rooted at the top module.
    test('what each property reads: the signals its expression names', () {
      final facts = _facts('fifo_slang', 'cov');
      // a_never_over: count <= D, disable iff (rst).
      final never = _onLine(facts, 'fifo_slang.sv', 38).reads;
      expect(never.first, 'fifo_slang.count');
      expect(never, contains('fifo_slang.rst'));
      // a_full_empty: !(full && empty); both are decoded from count.
      expect(
        _onLine(facts, 'fifo_slang.sv', 39).reads,
        containsAll(<String>['fifo_slang.full', 'fifo_slang.empty']),
      );
      // a_rose_full: $rose(full) || $past(wr), read through `$past`.
      expect(
        _onLine(facts, 'fifo_slang.sv', 41).reads,
        containsAll(<String>['fifo_slang.full', 'fifo_slang.wr']),
      );
      // c_drain: $past(full, 4) && empty.
      expect(
        _onLine(facts, 'fifo_slang.sv', 47).reads,
        containsAll(<String>['fifo_slang.full', 'fifo_slang.empty']),
      );
      for (final cell in facts.cells) {
        // Never the clock (a check's trigger, not its expression), never a
        // signal behind a design register, never an internal name.
        expect(cell.reads, isNot(contains('fifo_slang.clk')), reason: '$cell');
        expect(
          cell.reads,
          isNot(contains('fifo_slang.wdata')),
          reason: '$cell',
        );
        expect(
          cell.reads.where((r) => r.contains(r'$')),
          isEmpty,
          reason: '$cell',
        );
        expect(
          cell.reads.length,
          lessThanOrEqualTo(PretraceDetector.kMaxReads),
        );
      }
    });

    test('every formal cell is found, with its kind', () {
      final facts = _facts('fifo_slang', 'cov');
      expect(facts.count('assert'), 5);
      expect(facts.count('assume'), 1);
      expect(facts.count('cover'), 2);
    });
  });

  group('pretrace (both frontends)', () {
    final expected = readJsonObject(
      p.join(kFormalFixtureRoot, 'sby/pretrace/pretrace.expected.json'),
    );
    final tasks = expected['tasks']! as Map<String, Object?>;
    for (final task in tasks.keys) {
      test('$task: every property has the hand-expected depth', () {
        final facts = _facts('pretrace', task);
        final spec = tasks[task]! as Map<String, Object?>;
        for (final prop in objectList(spec['properties'])) {
          final want =
              (prop['pretrace']! as Map<String, Object?>)['past_depth'];
          expect(
            _onLine(facts, 'pretrace.sv', prop['line']! as int).pastDepth,
            want,
            reason: '$task line ${prop['line']}',
          );
        }
      });
    }

    test("at() matches sby's spelling of a location, then file and line", () {
      final facts = _facts('pretrace', 'slang_cover');
      final exact = facts.cells.firstWhere(
        (c) => c.location.startsWith('pretrace.sv:15.'),
      );
      expect(facts.at(exact.location), exact);
      expect(facts.at('src/pretrace.sv:15'), exact);
      expect(facts.at('pretrace.sv:99.1-99.2'), isNull);
    });
  });
}
