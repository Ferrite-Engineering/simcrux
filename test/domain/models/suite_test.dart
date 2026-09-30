// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_spec.dart';

TestSpec _spec(String id) {
  return TestSpec(
    id: id,
    name: id,
    suiteName: 'cpu_unit',
    simulatorId: 'icarus',
    top: 'tb',
  );
}

void main() {
  group('Suite', () {
    test('tests list is wrapped unmodifiable', () {
      final suite = Suite(name: 'cpu_unit', tests: [_spec('t1')]);
      expect(() => suite.tests.add(_spec('t2')), throwsUnsupportedError);
    });

    test('copyWith replaces fields', () {
      final suite = Suite(name: 'cpu_unit', tests: [_spec('t1')]);
      final updated = suite.copyWith(
        description: 'CPU unit tests',
        tests: [_spec('t1'), _spec('t2')],
      );
      expect(updated.description, 'CPU unit tests');
      expect(updated.tests.length, 2);
      expect(updated.name, 'cpu_unit');
    });

    test('equality compares name, description, tests', () {
      final a = Suite(name: 'cpu_unit', tests: [_spec('t1')]);
      final b = Suite(name: 'cpu_unit', tests: [_spec('t1')]);
      final c = Suite(name: 'cpu_unit', tests: [_spec('t2')]);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });
  });
}
