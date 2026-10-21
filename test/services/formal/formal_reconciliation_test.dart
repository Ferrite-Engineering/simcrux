// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/formal_property_status.dart';
import 'package:simcrux/domain/enums/formal_verdict.dart';
import 'package:simcrux/services/formal/formal_reconciliation.dart';
import 'package:simcrux/services/formal/sby_status_database.dart';
import 'package:simcrux/services/formal/sby_status_reader.dart';

// The agreement rule (VERIFICATION_GUIDE.md §26.8): the more conservative
// fact wins, the disagreement is recorded, and nothing is ever resolved
// toward Proved.

SbyStatusRecord _r(
  String status, {
  String kind = 'ASSERT',
  String location = 'a.sv:3.1-3.9',
  String name = 'top.a_x',
  String mode = 'prove',
  int? depth,
  String? trace,
}) => SbyStatusRecord(
  task: 't',
  kind: kind,
  location: location,
  name: name,
  status: status,
  mode: mode,
  depth: depth,
  trace: trace,
  induction: trace != null && SbyStatusRecord.isInductionTrace(trace),
);

SbyStatusReader _live(List<SbyStatusRecord> records) {
  final reader = SbyStatusReader(task: 't');
  records.forEach(reader.add);
  return reader;
}

SbyStatusSnapshot _db({
  List<SbyDeclaredProperty> properties = const [],
  List<SbyStatusRecord> records = const [],
}) => SbyStatusSnapshot(
  properties: properties,
  records: records,
  truncated: false,
);

SbyDeclaredProperty _declared(
  String location, {
  String kind = 'ASSERT',
  String name = '',
}) => SbyDeclaredProperty(
  task: 't',
  kind: kind,
  location: location,
  name: name,
);

void main() {
  group('task PASS', () {
    test('and every property proved: PASS, agreed', () {
      final r = FormalReconciliation.reconcile(
        taskVerdict: FormalVerdict.pass,
        proofMode: null,
        live: _live([_r('PASS')]),
      );
      expect(r.verdict, FormalVerdict.pass);
      expect(r.disagreement, isFalse);
    });

    test('but a property FAIL: FAIL, disagreement recorded', () {
      final r = FormalReconciliation.reconcile(
        taskVerdict: FormalVerdict.pass,
        proofMode: null,
        live: _live([
          _r('PASS'),
          _r('FAIL', location: 'a.sv:4.1-4.9', depth: 3),
        ]),
      );
      expect(r.verdict, FormalVerdict.fail);
      expect(r.taskVerdict, FormalVerdict.pass);
      expect(r.disagreement, isTrue);
      expect(r.failedCount, 1);
    });

    test('but a property only UNKNOWN: UNKNOWN, never PASS', () {
      final r = FormalReconciliation.reconcile(
        taskVerdict: FormalVerdict.pass,
        proofMode: null,
        live: _live([_r('PASS'), _r('UNKNOWN', location: 'a.sv:4.1-4.9')]),
      );
      expect(r.verdict, FormalVerdict.unknown);
      expect(r.disagreement, isTrue);
      expect(r.undecidedCount, 1);
    });

    test('but a declared property has no status at all: Did not run', () {
      final r = FormalReconciliation.reconcile(
        taskVerdict: FormalVerdict.pass,
        proofMode: null,
        live: _live([_r('PASS')]),
        database: _db(properties: [_declared('a.sv:7.1-7.2')]),
      );
      final missing = r.properties.singleWhere(
        (x) => x.rawLocation == 'a.sv:7.1-7.2',
      );
      expect(missing.status, FormalPropertyStatus.didNotRun);
      expect(r.verdict, FormalVerdict.noOutcome);
      expect(r.disagreement, isTrue);
    });
  });

  group('task not PASS: its verdict stands, never moved toward PASS', () {
    test('UNKNOWN with every property proved stays UNKNOWN', () {
      final r = FormalReconciliation.reconcile(
        taskVerdict: FormalVerdict.unknown,
        proofMode: null,
        live: _live([_r('PASS')]),
      );
      expect(r.verdict, FormalVerdict.unknown);
      expect(r.disagreement, isTrue);
    });

    test('FAIL with no failing property stays FAIL', () {
      final r = FormalReconciliation.reconcile(
        taskVerdict: FormalVerdict.fail,
        proofMode: null,
        live: _live([_r('PASS')]),
      );
      expect(r.verdict, FormalVerdict.fail);
      expect(r.disagreement, isTrue);
    });

    for (final verdict in FormalVerdict.values.where((v) => !v.proved)) {
      test(
        '${verdict.wireName} with all properties proved never reads PASS',
        () {
          final r = FormalReconciliation.reconcile(
            taskVerdict: verdict,
            proofMode: null,
            live: _live([_r('PASS')]),
            database: _db(records: [_r('PASS')]),
          );
          expect(r.verdict, verdict);
          expect(r.verdict.proved, isFalse);
        },
      );
    }

    test('a property with no record under a FAIL is undecided', () {
      final r = FormalReconciliation.reconcile(
        taskVerdict: FormalVerdict.fail,
        proofMode: null,
        live: _live([_r('FAIL', depth: 2, trace: 'x/engine_0/trace.vcd')]),
        database: _db(properties: [_declared('a.sv:8.1-8.2')]),
      );
      expect(
        r.properties.singleWhere((x) => x.line == 8).status,
        FormalPropertyStatus.inconclusive,
      );
      expect(r.disagreement, isFalse);
    });
  });

  test('stream and status.sqlite disagreeing: the conservative one wins', () {
    final r = FormalReconciliation.reconcile(
      taskVerdict: FormalVerdict.pass,
      proofMode: null,
      live: _live([_r('PASS')]),
      database: _db(records: [_r('UNKNOWN')]),
    );
    expect(r.properties.single.status, FormalPropertyStatus.inconclusive);
    expect(r.verdict, FormalVerdict.unknown);
    expect(r.disagreement, isTrue);
  });

  test('status.sqlite fills in a property the stream never mentioned', () {
    final r = FormalReconciliation.reconcile(
      taskVerdict: FormalVerdict.pass,
      proofMode: null,
      live: _live(const []),
      database: _db(records: [_r('PASS')]),
    );
    expect(r.properties.single.status, FormalPropertyStatus.proved);
    expect(r.verdict, FormalVerdict.pass);
  });

  test('no per-property data: the log verdict, no disagreement claimed', () {
    final r = FormalReconciliation.reconcile(
      taskVerdict: FormalVerdict.pass,
      proofMode: null,
      live: _live(const []),
    );
    expect(r.verdict, FormalVerdict.pass);
    expect(r.disagreement, isNull);
    expect(r.properties, isEmpty);
  });

  group('only the kinds the mode checks count', () {
    test("a prove task ignores the design's cover statements", () {
      final r = FormalReconciliation.reconcile(
        taskVerdict: FormalVerdict.pass,
        proofMode: null,
        live: _live([_r('PASS')]),
        database: _db(
          properties: [_declared('a.sv:9.1-9.2', kind: 'COVER')],
        ),
      );
      expect(r.properties.map((x) => x.kind), ['ASSERT']);
      expect(r.verdict, FormalVerdict.pass);
    });

    test('a cover task ignores the assertions', () {
      final r = FormalReconciliation.reconcile(
        taskVerdict: FormalVerdict.pass,
        proofMode: null,
        live: _live([
          _r('PASS', kind: 'COVER', mode: 'cover', depth: 5),
        ]),
        database: _db(properties: [_declared('a.sv:3.1-3.9')]),
      );
      expect(r.properties.single.status, FormalPropertyStatus.reached);
      expect(r.properties.single.step, 5);
    });

    test('assumptions are never results', () {
      final r = FormalReconciliation.reconcile(
        taskVerdict: FormalVerdict.pass,
        proofMode: 'prove',
        live: _live([_r('PASS')]),
        database: _db(
          properties: [_declared('a.sv:1.1-1.2', kind: 'ASSUME')],
        ),
      );
      expect(r.properties.map((x) => x.kind), ['ASSERT']);
    });
  });

  group('identity and display', () {
    test('a yosys-slang label survives; a mangled name has none', () {
      expect(FormalReconciliation.labelOf('fifo.a_never_over'), 'a_never_over');
      expect(
        FormalReconciliation.labelOf(
          'handshake_imm._witness_.check_handshake_imm_sv_45_assert_28',
        ),
        isNull,
      );
      expect(FormalReconciliation.labelOf(r'top.$assert$a.sv:3'), isNull);
      expect(FormalReconciliation.labelOf('bare'), isNull);
    });

    test('display name is the label, else kind @ file:line', () {
      final r = FormalReconciliation.reconcile(
        taskVerdict: FormalVerdict.pass,
        proofMode: null,
        live: _live([
          _r('PASS'),
          _r('PASS', location: 'a.sv:4.1-4.9', name: 'top._witness_.c'),
        ]),
      );
      expect(r.properties.map((x) => x.displayName), [
        'a_x',
        'assert @ a.sv:4',
      ]);
      expect(r.properties.first.crossRunIdentity, 'a_x');
      expect(r.properties.last.crossRunIdentity, isNull);
    });

    test('a location maps back through [files] to the project file', () {
      final project = Directory.systemTemp.createTempSync('formal_loc_');
      addTearDown(() => project.deleteSync(recursive: true));
      final formal = Directory(p.join(project.path, 'formal'))..createSync();
      Directory(p.join(project.path, 'rtl')).createSync();
      final where = FormalReconciliation.normaliseLocation(
        'fifo.sv:38.3-38.79',
        files: const {'fifo.sv': '../rtl/fifo.sv'},
        sbyDirectory: formal.path,
        projectRoot: project.path,
      );
      expect(where.location, 'rtl/fifo.sv:38.3-38.79');
      expect(where.file, 'rtl/fifo.sv');
      expect(where.line, 38);
    });

    test('a source outside the project keeps the spelling sby used', () {
      final project = Directory.systemTemp.createTempSync('formal_loc_');
      addTearDown(() => project.deleteSync(recursive: true));
      final where = FormalReconciliation.normaliseLocation(
        'x.sv:2.1-2.3',
        files: const {'x.sv': '/elsewhere/x.sv'},
        sbyDirectory: project.path,
        projectRoot: project.path,
      );
      expect(where.location, 'x.sv:2.1-2.3');
      expect(where.line, 2);
    });
  });
}
