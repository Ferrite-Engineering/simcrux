// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/output_config.dart';

void main() {
  group('OutputConfig', () {
    test('defaults', () {
      const c = OutputConfig();
      expect(c.streaming, isFalse);
      expect(c.streamingResultsPath, isNull);
      expect(c.streamingSummaryPath, isNull);
    });

    test('copyWith', () {
      const c = OutputConfig();
      final next = c.copyWith(streaming: true, streamingResultsPath: '/x.nd');
      expect(next.streaming, isTrue);
      expect(next.streamingResultsPath, '/x.nd');
      expect(next.streamingSummaryPath, isNull);
    });

    test('equality & hash', () {
      const a = OutputConfig(streaming: true, streamingResultsPath: '/x');
      const b = OutputConfig(streaming: true, streamingResultsPath: '/x');
      const c = OutputConfig(streamingResultsPath: '/x');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });
}
