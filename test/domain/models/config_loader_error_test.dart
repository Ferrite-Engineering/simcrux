// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/config_loader_error.dart';

void main() {
  group('ConfigLoaderError', () {
    test('formats with line and column when present', () {
      const error = ConfigLoaderError(
        path: '/project/simcrux.yaml',
        message: 'Missing required field `version`.',
        line: 3,
        column: 5,
      );
      expect(
        error.format(),
        '/project/simcrux.yaml:3:5: Missing required field `version`.',
      );
    });

    test('format() falls back to path:message when span absent', () {
      const error = ConfigLoaderError.generic(
        path: '/project/simcrux.yaml',
        message: 'Unsupported schema version "2".',
      );
      expect(
        error.format(),
        '/project/simcrux.yaml: Unsupported schema version "2".',
      );
    });

    test('value-based equality', () {
      const a = ConfigLoaderError(
        path: '/p.yaml',
        message: 'm',
        line: 1,
        column: 2,
      );
      const b = ConfigLoaderError(
        path: '/p.yaml',
        message: 'm',
        line: 1,
        column: 2,
      );
      const c = ConfigLoaderError(
        path: '/p.yaml',
        message: 'm',
        line: 9,
        column: 2,
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });
  });

  group('ConfigLoaderException', () {
    test('single-error toString uses inline format', () {
      final exception = ConfigLoaderException([
        const ConfigLoaderError(
          path: '/p.yaml',
          message: 'm',
          line: 1,
          column: 1,
        ),
      ]);
      expect(exception.toString(), contains('/p.yaml:1:1: m'));
    });

    test('multi-error toString joins with newlines', () {
      final exception = ConfigLoaderException([
        const ConfigLoaderError(
          path: '/p.yaml',
          message: 'first',
          line: 1,
          column: 1,
        ),
        const ConfigLoaderError(
          path: '/p.yaml',
          message: 'second',
          line: 2,
          column: 1,
        ),
      ]);
      final str = exception.toString();
      expect(str, contains('(2 errors)'));
      expect(str, contains('  - /p.yaml:1:1: first'));
      expect(str, contains('  - /p.yaml:2:1: second'));
    });

    test('errors list is unmodifiable', () {
      final exception = ConfigLoaderException([
        const ConfigLoaderError.generic(path: '/p', message: 'm'),
      ]);
      expect(
        () => exception.errors.add(
          const ConfigLoaderError.generic(path: '/q', message: 'n'),
        ),
        throwsUnsupportedError,
      );
    });
  });
}
