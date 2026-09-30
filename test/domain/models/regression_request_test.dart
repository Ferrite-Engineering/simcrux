// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/test_spec.dart';

TestSpec _spec(String id) => TestSpec(
  id: id,
  name: id,
  suiteName: 's',
  simulatorId: 'icarus',
  top: 'tb',
);

void main() {
  group('RegressionRequest', () {
    test('default concurrency = 1 and defaultTimeout = 300s', () {
      final req = RegressionRequest(runId: 'r', tests: [_spec('t1')]);
      expect(req.concurrency, 1);
      expect(req.defaultTimeout, const Duration(seconds: 300));
    });

    test('tests list is wrapped unmodifiable', () {
      final req = RegressionRequest(runId: 'r', tests: [_spec('t1')]);
      expect(() => req.tests.add(_spec('t2')), throwsUnsupportedError);
    });

    test('copyWith replaces fields', () {
      final req = RegressionRequest(runId: 'r', tests: [_spec('t1')]);
      final updated = req.copyWith(concurrency: 8);
      expect(updated.concurrency, 8);
      expect(updated.runId, 'r');
    });

    test('equality compares every field', () {
      final a = RegressionRequest(runId: 'r', tests: [_spec('t1')]);
      final b = RegressionRequest(runId: 'r', tests: [_spec('t1')]);
      final c = RegressionRequest(runId: 'r', tests: [_spec('t2')]);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });
  });
}
