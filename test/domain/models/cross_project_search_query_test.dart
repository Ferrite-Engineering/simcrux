// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/cross_project_search_scope.dart';
import 'package:simcrux/domain/models/cross_project_search_query.dart';

void main() {
  group('CrossProjectSearchQuery', () {
    test('defaults: scope.all + caseInsensitive + 200-cap limit', () {
      const q = CrossProjectSearchQuery(pattern: 'foo');
      expect(q.pattern, 'foo');
      expect(q.scope, CrossProjectSearchScope.all);
      expect(q.caseSensitive, false);
      expect(q.limit, CrossProjectSearchQuery.defaultPerProjectLimit);
      expect(q.limit, 200);
    });

    test('isEmpty true only for empty pattern', () {
      expect(const CrossProjectSearchQuery(pattern: '').isEmpty, true);
      expect(const CrossProjectSearchQuery(pattern: 'a').isEmpty, false);
    });

    test('toJson / fromJson round-trip preserves every field', () {
      const q = CrossProjectSearchQuery(
        pattern: 'a*b',
        scope: CrossProjectSearchScope.failureMessages,
        caseSensitive: true,
        limit: 50,
      );
      final decoded = CrossProjectSearchQuery.fromJson(q.toJson());
      expect(decoded, equals(q));
    });

    test('fromJson tolerates unknown scope by falling back to all', () {
      final decoded = CrossProjectSearchQuery.fromJson(<String, Object?>{
        'pattern': 'x',
        'scope': 'someFutureScope',
        'case_sensitive': false,
        'limit': 10,
      });
      expect(decoded, isNotNull);
      expect(decoded!.scope, CrossProjectSearchScope.all);
    });

    test('fromJson rejects non-string pattern', () {
      expect(
        CrossProjectSearchQuery.fromJson(<String, Object?>{
          'pattern': 42,
        }),
        isNull,
      );
    });

    test('fromJson preserves explicit null limit', () {
      final decoded = CrossProjectSearchQuery.fromJson(<String, Object?>{
        'pattern': 'x',
        'scope': 'all',
        'case_sensitive': false,
        'limit': null,
      });
      expect(decoded, isNotNull);
      expect(decoded!.limit, isNull);
    });

    test('equality + hashCode field-by-field', () {
      const a = CrossProjectSearchQuery(
        pattern: 'a',
        scope: CrossProjectSearchScope.testNames,
      );
      const b = CrossProjectSearchQuery(
        pattern: 'a',
        scope: CrossProjectSearchScope.testNames,
      );
      const c = CrossProjectSearchQuery(
        pattern: 'a',
        scope: CrossProjectSearchScope.filePaths,
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });
  });
}
