// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/formal_property_status.dart';
import 'package:simcrux/domain/enums/formal_verdict.dart';
import 'package:simcrux/services/formal/sby_status_reader.dart';

// The `--live jsonl` reader: the record shape measured across sby 0.68 to
// 0.70 (VERIFICATION_GUIDE.md §26.4), fed line by line from the run log.

String _line(String json, {String job = '/w/t'}) =>
    'SBY 15:27:02 [$job] jsonl: $json';

String _record({
  String task = 'prove',
  String kind = 'ASSERT',
  String location = 'a.sv:3.1-3.9',
  String name = 'top.a_x',
  String status = 'UNKNOWN',
  int? depth,
  String? trace,
  String mode = 'prove',
}) =>
    '{"time": 0.1, "task_name": "$task", "mode": "$mode", '
    '"engine": "engine_0", "name": "$name", "location": "$location", '
    '"kind": "$kind", "status": "$status"'
    '${trace == null ? '' : ', "trace": "$trace"'}'
    '${depth == null ? '' : ', "depth": $depth'}}';

void main() {
  test('reads records out of the log and ignores every other line', () {
    final reader = SbyStatusReader()
      ..addLine('SBY 15:27:02 [/w/t] engine_0: smtbmc yices')
      ..addLine(_line(_record()))
      ..addLine(_line(_record(status: 'PASS', depth: 11)))
      ..addLine('SBY 15:27:02 [/w/t] DONE (PASS, rc=0)');
    expect(reader.recordCount, 2);
    expect(reader.mode, 'prove');
    final fold = reader.properties.single;
    expect(fold.status, FormalPropertyStatus.proved);
    expect(fold.step, isNull, reason: 'a proof has no witness step');
  });

  test('a line without the SBY prefix (a tee wrapper) still parses', () {
    final reader = SbyStatusReader()..addLine('jsonl: ${_record()}');
    expect(reader.recordCount, 1);
  });

  test('a base-case FAIL wins over a later PASS', () {
    final reader = SbyStatusReader()
      ..addLine(
        _line(
          _record(status: 'FAIL', depth: 6, trace: 'x/engine_0/trace.vcd'),
        ),
      )
      ..addLine(_line(_record(status: 'PASS', depth: 11)));
    final fold = reader.properties.single;
    expect(fold.status, FormalPropertyStatus.counterexample);
    expect(fold.step, 6);
  });

  test('an induction FAIL alone is inconclusive, never a counterexample', () {
    final reader = SbyStatusReader()
      ..addLine(
        _line(_record(status: 'FAIL', trace: 'x/engine_0/trace_induct.vcd')),
      );
    final fold = reader.properties.single;
    expect(fold.inductionFailed, isTrue);
    expect(fold.status, FormalPropertyStatus.inconclusive);
    expect(fold.trace, isNull);
  });

  test('the VCD is preferred over the .yw witness the record may name', () {
    final reader = SbyStatusReader()
      ..addLine(
        _line(_record(status: 'FAIL', depth: 6, trace: 'x/engine_0/trace.yw')),
      )
      ..addLine(
        _line(_record(status: 'FAIL', depth: 6, trace: 'x/engine_0/trace.vcd')),
      );
    expect(reader.properties.single.trace, 'x/engine_0/trace.vcd');
  });

  test('covers: PASS is reached at its step, FAIL is not reached', () {
    final reader = SbyStatusReader()
      ..addLine(
        _line(
          _record(
            kind: 'COVER',
            location: 'a.sv:9.1-9.4',
            status: 'PASS',
            depth: 5,
            trace: 'x/engine_0/trace0.vcd',
            mode: 'cover',
          ),
        ),
      )
      ..addLine(
        _line(
          _record(
            kind: 'COVER',
            location: 'a.sv:10.1-10.4',
            status: 'FAIL',
            mode: 'cover',
          ),
        ),
      );
    final [reached, unreached] = reader.properties;
    expect(reached.status, FormalPropertyStatus.reached);
    expect(reached.step, 5);
    expect(unreached.status, FormalPropertyStatus.notReached);
  });

  test('a status token a newer sby invents is never a proof', () {
    final reader = SbyStatusReader()
      ..addLine(_line(_record(status: 'PASS')))
      ..addLine(_line(_record(status: 'VACUOUS')));
    expect(reader.properties.single.status, FormalPropertyStatus.inconclusive);
  });

  test('properties are keyed on task, kind and location, not name', () {
    final reader = SbyStatusReader()
      ..addLine(_line(_record(name: 'top._witness_.check_a_3_1')))
      ..addLine(_line(_record(name: 'top._witness_.check_a_3_2')))
      ..addLine(_line(_record(location: 'a.sv:4.1-4.9')));
    expect(reader.properties, hasLength(2));
  });

  test('a task filter drops other tasks of an interleaved log', () {
    final reader = SbyStatusReader(task: 'bug')
      ..addLine(_line(_record(task: 'ok')))
      ..addLine(_line(_record(task: 'bug')));
    expect(reader.properties.single.task, 'bug');
  });

  group('bounded', () {
    test('a malformed or oversized record is counted, not decoded', () {
      final reader = SbyStatusReader()
        ..addLine(_line('{"task_name": '))
        ..addLine(_line('{"no": "fields"}'))
        ..addLine(_line('${_record()}${' ' * SbyStatusReader.kMaxLineLength}'));
      expect(reader.recordCount, 0);
      expect(reader.malformedCount, 3);
    });

    test('properties beyond the cap are dropped and flagged', () {
      final reader = SbyStatusReader();
      for (var i = 0; i <= SbyStatusReader.kMaxProperties; i++) {
        reader.add(
          SbyStatusRecord(
            task: 't',
            kind: 'ASSERT',
            location: 'a.sv:$i.1-$i.2',
            name: '',
            status: 'PASS',
          ),
        );
      }
      expect(reader.properties, hasLength(SbyStatusReader.kMaxProperties));
      expect(reader.truncated, isTrue);
    });
  });

  test('the properties alone never support a proof they do not show', () {
    expect(
      verdictFromProperties(const [
        FormalPropertyStatus.proved,
        FormalPropertyStatus.inconclusive,
      ]),
      FormalVerdict.unknown,
    );
    expect(
      verdictFromProperties(const [
        FormalPropertyStatus.didNotRun,
        FormalPropertyStatus.inconclusive,
      ]),
      FormalVerdict.noOutcome,
    );
    expect(
      verdictFromProperties(const [
        FormalPropertyStatus.didNotRun,
        FormalPropertyStatus.counterexample,
      ]),
      FormalVerdict.fail,
    );
  });
}
