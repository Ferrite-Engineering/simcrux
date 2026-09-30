// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/interfaces/cross_project_search_service.dart';
import 'package:simcrux/domain/models/cross_project_search_progress.dart';
import 'package:simcrux/domain/models/cross_project_search_query.dart';

void main() {
  group('NoopCrossProjectSearchService', () {
    test('search emits zero matches and closes', () async {
      final service = NoopCrossProjectSearchService();
      addTearDown(service.dispose);
      const query = CrossProjectSearchQuery(pattern: 'foo');
      final matches = await service.search(query).toList();
      expect(matches, isEmpty);
    });

    test('progress emits emptyWorkspace event when search is called', () async {
      final service = NoopCrossProjectSearchService();
      addTearDown(service.dispose);
      final progressEvents = <CrossProjectSearchProgress>[];
      final sub = service.progress.listen(progressEvents.add);
      addTearDown(sub.cancel);
      const query = CrossProjectSearchQuery(pattern: 'foo');
      service.search(query).listen((_) {}); // drain to keep coverage
      await Future<void>.delayed(Duration.zero);
      expect(progressEvents, hasLength(1));
      expect(progressEvents.first, CrossProjectSearchProgress.emptyWorkspace);
    });

    test('cancelActiveSearch completes without throwing', () async {
      final service = NoopCrossProjectSearchService();
      addTearDown(service.dispose);
      await service.cancelActiveSearch();
    });
  });
}
