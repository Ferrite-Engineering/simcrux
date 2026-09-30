// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/test_result.dart';

TestResult _result({TestStatus status = TestStatus.pass}) {
  return TestResult(
    testId: 'cpu_unit/alu_basic',
    runId: 'run-1',
    status: status,
    startedAt: DateTime.utc(2026, 5, 22, 10),
    finishedAt: DateTime.utc(2026, 5, 22, 10, 0, 5),
  );
}

void main() {
  group('TestResult', () {
    test('runtime computes finishedAt - startedAt', () {
      final r = _result();
      expect(r.runtime, const Duration(seconds: 5));
    });

    test('asserts finishedAt is not before startedAt', () {
      expect(
        () => TestResult(
          testId: 't',
          runId: 'r',
          status: TestStatus.pass,
          startedAt: DateTime.utc(2026, 5, 22, 10, 0, 5),
          finishedAt: DateTime.utc(2026, 5, 22, 10),
        ),
        throwsAssertionError,
      );
    });

    test('metrics is wrapped in an unmodifiable map', () {
      final r = _result().copyWith(metrics: {'coverage': '92.3'});
      expect(() => r.metrics['x'] = 'y', throwsUnsupportedError);
    });

    test('copyWith replaces individual fields', () {
      final r = _result();
      final updated = r.copyWith(
        status: TestStatus.fail,
        failureMessage: 'Expected 0x42, got 0x41',
      );
      expect(updated.status, TestStatus.fail);
      expect(updated.failureMessage, 'Expected 0x42, got 0x41');
      expect(updated.testId, r.testId);
    });

    test('equality compares every field', () {
      final a = _result();
      final b = _result();
      final c = _result(status: TestStatus.fail);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });

    test('executionSeed defaults to null', () {
      final r = _result();
      expect(r.executionSeed, isNull);
    });

    test('executionSeed round-trips through copyWith', () {
      final r = _result().copyWith(executionSeed: 1234);
      expect(r.executionSeed, 1234);
      final r2 = r.copyWith();
      expect(r2.executionSeed, 1234);
    });

    test('executionSeed participates in equality and hashCode', () {
      final a = _result().copyWith(executionSeed: 42);
      final b = _result().copyWith(executionSeed: 42);
      final c = _result().copyWith(executionSeed: 43);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });

    test('boundParameters and parentSpecId default to null', () {
      final r = _result();
      expect(r.boundParameters, isNull);
      expect(r.parentSpecId, isNull);
    });

    test('boundParameters round-trips through copyWith and ==', () {
      final r = _result().copyWith(
        boundParameters: const {'mode': 'fast', 'dataWidth': '16'},
      );
      expect(r.boundParameters, {'mode': 'fast', 'dataWidth': '16'});
      final r2 = r.copyWith();
      expect(r2.boundParameters, {'mode': 'fast', 'dataWidth': '16'});
      // Map is unmodifiable.
      expect(() => r.boundParameters!['extra'] = 'x', throwsUnsupportedError);
      // Equality.
      final r3 = _result().copyWith(
        boundParameters: const {'mode': 'fast', 'dataWidth': '16'},
      );
      expect(r, equals(r3));
      expect(r.hashCode, r3.hashCode);
      expect(r, isNot(equals(_result())));
    });

    test('clearBoundParameters drops the field back to null', () {
      final r = _result().copyWith(
        boundParameters: const {'mode': 'fast'},
      );
      final cleared = r.copyWith(clearBoundParameters: true);
      expect(cleared.boundParameters, isNull);
    });

    test('parentSpecId round-trips through copyWith and ==', () {
      final r = _result().copyWith(parentSpecId: 'unit/alu');
      expect(r.parentSpecId, 'unit/alu');
      final r2 = _result().copyWith(parentSpecId: 'unit/alu');
      expect(r, equals(r2));
      expect(r.hashCode, r2.hashCode);
      expect(r, isNot(equals(_result())));
      // clearParentSpecId returns it to null.
      expect(r.copyWith(clearParentSpecId: true).parentSpecId, isNull);
    });
  });
}
