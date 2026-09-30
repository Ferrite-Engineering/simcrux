// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/pr_annotation.dart';

void main() {
  group('PrAnnotation', () {
    test('equality compares every field including extraMetadata entries', () {
      final a = PrAnnotation(
        targetKind: PrAnnotationTargetKind.annotation,
        severity: PrAnnotationSeverity.error,
        title: 'CRC mismatch',
        message: 'Test foo failed at line 42',
        filePath: 'rtl/foo.sv',
        lineNumber: 42,
        extraMetadata: const {'category': 'protocol'},
      );
      final b = PrAnnotation(
        targetKind: PrAnnotationTargetKind.annotation,
        severity: PrAnnotationSeverity.error,
        title: 'CRC mismatch',
        message: 'Test foo failed at line 42',
        filePath: 'rtl/foo.sv',
        lineNumber: 42,
        extraMetadata: const {'category': 'protocol'},
      );
      final c = PrAnnotation(
        targetKind: PrAnnotationTargetKind.annotation,
        severity: PrAnnotationSeverity.warning, // diff
        title: 'CRC mismatch',
        message: 'Test foo failed at line 42',
        filePath: 'rtl/foo.sv',
        lineNumber: 42,
        extraMetadata: const {'category': 'protocol'},
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });

    test('copyWith replaces only the fields supplied', () {
      final original = PrAnnotation(
        targetKind: PrAnnotationTargetKind.annotation,
        severity: PrAnnotationSeverity.error,
        title: 'X',
        message: 'M',
        filePath: 'a/b.sv',
        lineNumber: 10,
      );
      final updated = original.copyWith(severity: PrAnnotationSeverity.notice);
      expect(updated.severity, PrAnnotationSeverity.notice);
      expect(updated.title, 'X');
      expect(updated.filePath, 'a/b.sv');
      expect(updated.lineNumber, 10);
    });

    test('extraMetadata defaults to empty + is unmodifiable', () {
      final a = PrAnnotation(
        targetKind: PrAnnotationTargetKind.comment,
        severity: PrAnnotationSeverity.notice,
        title: 't',
        message: 'm',
      );
      expect(a.extraMetadata, isEmpty);
      expect(() => a.extraMetadata['k'] = 'v', throwsUnsupportedError);
    });

    test('toString does NOT include message body (safe-logging contract)', () {
      final a = PrAnnotation(
        targetKind: PrAnnotationTargetKind.annotation,
        severity: PrAnnotationSeverity.error,
        title: 'Title',
        message: 'sensitive-message-body-that-should-not-leak',
      );
      expect(a.toString(), isNot(contains('sensitive-message-body')));
    });
  });
}
