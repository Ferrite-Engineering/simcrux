// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/cross_project_search_match.dart';
import 'package:simcrux/domain/models/cross_project_search_target.dart';

void main() {
  group('computeHighlights', () {
    test('empty pattern returns no ranges', () {
      expect(
        computeHighlights(
          pattern: '',
          haystack: 'anything',
          caseSensitive: false,
        ),
        isEmpty,
      );
    });

    test('case-insensitive single literal match', () {
      final hits = computeHighlights(
        pattern: 'Foo',
        haystack: 'before fOO after',
        caseSensitive: false,
      );
      expect(hits, hasLength(1));
      expect(hits.first.start, 7);
      expect(hits.first.end, 10);
    });

    test('case-sensitive: no match when case mismatches', () {
      final hits = computeHighlights(
        pattern: 'Foo',
        haystack: 'before foo after',
        caseSensitive: true,
      );
      expect(hits, isEmpty);
    });

    test('glob with leading and trailing wildcard matches anywhere', () {
      final hits = computeHighlights(
        pattern: '*foo*',
        haystack: 'leading foo trailing',
        caseSensitive: false,
      );
      expect(hits, hasLength(1));
      expect(hits.first.start, 8);
      expect(hits.first.end, 11);
    });

    test('two-segment glob matches segments in order', () {
      final hits = computeHighlights(
        pattern: 'foo*bar',
        haystack: 'foo XYZ bar baz',
        caseSensitive: false,
      );
      expect(hits, hasLength(2));
      expect(hits[0].start, 0);
      expect(hits[0].end, 3);
      expect(hits[1].start, 8);
      expect(hits[1].end, 11);
    });

    test('two-segment glob misses when second segment absent', () {
      final hits = computeHighlights(
        pattern: 'foo*bar',
        haystack: 'foo XYZ baz',
        caseSensitive: false,
      );
      expect(hits, isEmpty);
    });
  });

  group('CrossProjectSearchHighlight', () {
    test('round-trips', () {
      const h = CrossProjectSearchHighlight(start: 3, end: 8);
      final decoded = CrossProjectSearchHighlight.fromJson(h.toJson());
      expect(decoded, equals(h));
    });

    test('fromJson rejects negative or inverted bounds', () {
      expect(
        CrossProjectSearchHighlight.fromJson(<String, Object?>{
          'start': -1,
          'end': 5,
        }),
        isNull,
      );
      expect(
        CrossProjectSearchHighlight.fromJson(<String, Object?>{
          'start': 5,
          'end': 3,
        }),
        isNull,
      );
    });
  });

  group('CrossProjectSearchMatch', () {
    test('round-trips with all fields', () {
      final m = CrossProjectSearchMatch(
        projectId: 'proj-1',
        projectName: 'Proj 1',
        matchKind: CrossProjectSearchMatchKind.testName,
        matchedText: 'foo',
        contextSnippet: 'context foo bar',
        highlights: const [CrossProjectSearchHighlight(start: 8, end: 11)],
        target: const CrossProjectSearchTestTarget(testId: 'foo'),
      );
      final decoded = CrossProjectSearchMatch.fromJson(m.toJson());
      expect(decoded, equals(m));
    });

    test('round-trips with failure target', () {
      final m = CrossProjectSearchMatch(
        projectId: 'proj-1',
        projectName: 'Proj 1',
        matchKind: CrossProjectSearchMatchKind.failureMessage,
        matchedText: 'assertion',
        contextSnippet: 'failed assertion at line 42',
        target: const CrossProjectSearchFailureTarget(
          testId: 'suite.test',
          runId: 'run-1',
          failureMessage: 'failed assertion at line 42',
        ),
      );
      final decoded = CrossProjectSearchMatch.fromJson(m.toJson());
      expect(decoded, equals(m));
    });

    test('fromJson rejects empty projectId', () {
      expect(
        CrossProjectSearchMatch.fromJson(<String, Object?>{
          'project_id': '',
          'project_name': 'p',
          'match_kind': 'testName',
          'matched_text': 'foo',
          'context_snippet': 'foo',
          'highlights': <Object?>[],
          'target': <String, Object?>{'kind': 'test', 'test_id': 'foo'},
        }),
        isNull,
      );
    });

    test('fromJson rejects target with bad kind', () {
      expect(
        CrossProjectSearchMatch.fromJson(<String, Object?>{
          'project_id': 'p',
          'project_name': 'p',
          'match_kind': 'testName',
          'matched_text': 'foo',
          'context_snippet': 'foo',
          'highlights': <Object?>[],
          'target': <String, Object?>{'kind': 'unknown'},
        }),
        isNull,
      );
    });

    test('equality differs when highlights differ', () {
      final a = CrossProjectSearchMatch(
        projectId: 'p',
        projectName: 'P',
        matchKind: CrossProjectSearchMatchKind.testName,
        matchedText: 'f',
        contextSnippet: 'f',
        target: const CrossProjectSearchTestTarget(testId: 'f'),
      );
      final b = CrossProjectSearchMatch(
        projectId: 'p',
        projectName: 'P',
        matchKind: CrossProjectSearchMatchKind.testName,
        matchedText: 'f',
        contextSnippet: 'f',
        highlights: const [CrossProjectSearchHighlight(start: 0, end: 1)],
        target: const CrossProjectSearchTestTarget(testId: 'f'),
      );
      expect(a, isNot(equals(b)));
    });
  });
}
