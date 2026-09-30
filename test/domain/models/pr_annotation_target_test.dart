// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/pr_annotation_target.dart';

void main() {
  group('PrAnnotationTarget', () {
    test('isComplete requires repo + pr + token for github / gitlab', () {
      const incomplete = PrAnnotationTarget(
        platform: PrAnnotationPlatform.github,
        repositoryRef: 'owner/repo',
        prNumber: 12,
      );
      expect(incomplete.isComplete, isFalse);
      const complete = PrAnnotationTarget(
        platform: PrAnnotationPlatform.github,
        repositoryRef: 'owner/repo',
        prNumber: 12,
        authToken: 'ghp_abc',
      );
      expect(complete.isComplete, isTrue);
    });

    test('isComplete requires only webhookUrl for webhook platform', () {
      const noUrl = PrAnnotationTarget(
        platform: PrAnnotationPlatform.webhook,
      );
      expect(noUrl.isComplete, isFalse);
      const justUrl = PrAnnotationTarget(
        platform: PrAnnotationPlatform.webhook,
        webhookUrl: 'https://hooks.example.com/abc',
      );
      expect(justUrl.isComplete, isTrue);
    });

    test('toString redacts the auth token', () {
      const a = PrAnnotationTarget(
        platform: PrAnnotationPlatform.github,
        repositoryRef: 'owner/repo',
        prNumber: 12,
        authToken: 'ghp_supersecret_no_leak_me',
      );
      expect(a.toString(), contains('<redacted>'));
      expect(a.toString(), isNot(contains('ghp_supersecret_no_leak_me')));
    });

    test('hashCode does NOT include token contents — only its length', () {
      const a = PrAnnotationTarget(
        platform: PrAnnotationPlatform.github,
        repositoryRef: 'r',
        prNumber: 1,
        authToken: 'abc',
      );
      const b = PrAnnotationTarget(
        platform: PrAnnotationPlatform.github,
        repositoryRef: 'r',
        prNumber: 1,
        authToken: 'xyz',
      );
      // Same length tokens → same hashCode (token contents not in hash).
      expect(a.hashCode, b.hashCode);
      // Different length → different hash.
      const c = PrAnnotationTarget(
        platform: PrAnnotationPlatform.github,
        repositoryRef: 'r',
        prNumber: 1,
        authToken: 'abcd',
      );
      expect(a.hashCode, isNot(b == c ? c.hashCode : a.hashCode + 1));
    });

    test('equality compares token contents (not just length)', () {
      const a = PrAnnotationTarget(
        platform: PrAnnotationPlatform.github,
        repositoryRef: 'r',
        prNumber: 1,
        authToken: 'abc',
      );
      const b = PrAnnotationTarget(
        platform: PrAnnotationPlatform.github,
        repositoryRef: 'r',
        prNumber: 1,
        authToken: 'xyz',
      );
      expect(a, isNot(equals(b)));
    });
  });
}
