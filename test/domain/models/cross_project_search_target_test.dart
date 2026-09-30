// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/cross_project_search_target.dart';

void main() {
  group('CrossProjectSearchTestTarget', () {
    test('round-trips with all fields', () {
      const t = CrossProjectSearchTestTarget(
        testId: 'suite.test',
        runId: 'run-1',
      );
      final decoded = CrossProjectSearchTarget.fromJson(t.toJson());
      expect(decoded, equals(t));
    });

    test('round-trips with null runId', () {
      const t = CrossProjectSearchTestTarget(testId: 'suite.test');
      final decoded = CrossProjectSearchTarget.fromJson(t.toJson());
      expect(decoded, equals(t));
    });

    test('fromJson rejects empty testId', () {
      expect(
        CrossProjectSearchTarget.fromJson(<String, Object?>{
          'kind': 'test',
          'test_id': '',
        }),
        isNull,
      );
    });
  });

  group('CrossProjectSearchFailureTarget', () {
    test('round-trips', () {
      const t = CrossProjectSearchFailureTarget(
        testId: 'suite.test',
        runId: 'run-1',
        failureMessage: 'Assertion failed at line 42',
      );
      final decoded = CrossProjectSearchTarget.fromJson(t.toJson());
      expect(decoded, equals(t));
    });

    test('fromJson rejects missing runId', () {
      expect(
        CrossProjectSearchTarget.fromJson(<String, Object?>{
          'kind': 'failure',
          'test_id': 'x',
          'failure_message': 'msg',
        }),
        isNull,
      );
    });
  });

  group('CrossProjectSearchSourceFileTarget', () {
    test('round-trips with line', () {
      const t = CrossProjectSearchSourceFileTarget(
        filePath: '/proj/src/x.sv',
        line: 42,
      );
      final decoded = CrossProjectSearchTarget.fromJson(t.toJson());
      expect(decoded, equals(t));
    });

    test('round-trips without line', () {
      const t = CrossProjectSearchSourceFileTarget(filePath: '/proj/src/x.sv');
      final decoded = CrossProjectSearchTarget.fromJson(t.toJson());
      expect(decoded, equals(t));
      expect((decoded! as CrossProjectSearchSourceFileTarget).line, isNull);
    });
  });

  test('CrossProjectSearchTarget.fromJson rejects unknown kind', () {
    expect(
      CrossProjectSearchTarget.fromJson(<String, Object?>{
        'kind': 'someFuture',
      }),
      isNull,
    );
  });

  test('CrossProjectSearchTarget.fromJson rejects non-map', () {
    expect(CrossProjectSearchTarget.fromJson(42), isNull);
    expect(CrossProjectSearchTarget.fromJson(null), isNull);
  });
}
