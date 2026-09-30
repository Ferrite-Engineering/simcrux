// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/interfaces/cross_project_search_service.dart';
import 'package:simcrux/domain/models/cross_project_search_match.dart';
import 'package:simcrux/domain/models/cross_project_search_progress.dart';
import 'package:simcrux/domain/models/cross_project_search_query.dart';
import 'package:simcrux/domain/models/cross_project_search_target.dart';
import 'package:simcrux/services/projects/cross_project_search_provider.dart';

void main() {
  group('crossProjectSearchServiceProvider', () {
    test('defaults to NoopCrossProjectSearchService', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final service = container.read(crossProjectSearchServiceProvider);
      expect(service, isA<NoopCrossProjectSearchService>());
    });

    test('Pro override replaces the default', () {
      final fake = _FakeService();
      final container = ProviderContainer(
        overrides: <Override>[
          crossProjectSearchServiceProvider.overrideWithValue(fake),
        ],
      );
      addTearDown(container.dispose);
      final service = container.read(crossProjectSearchServiceProvider);
      expect(service, same(fake));
    });
  });

  group('activeCrossProjectSearchProvider', () {
    test('starts idle with empty query + matches + progress', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final state = container.read(activeCrossProjectSearchProvider);
      expect(state.query.pattern, '');
      expect(state.matches, isEmpty);
      expect(state.progressByProject, isEmpty);
      expect(state.isSearching, false);
    });

    test('startSearch arms busy flag + clears matches and progress', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // Seed prior state to verify startSearch resets it.
      container
          .read(activeCrossProjectSearchProvider.notifier)
          .appendMatch(_match());
      container
          .read(activeCrossProjectSearchProvider.notifier)
          .updateProgress(
            const CrossProjectSearchProgress(
              projectId: 'p',
              projectName: 'P',
              status: CrossProjectSearchProgressStatus.searching,
            ),
          );
      container
          .read(activeCrossProjectSearchProvider.notifier)
          .startSearch(
            const CrossProjectSearchQuery(pattern: 'next'),
          );
      final state = container.read(activeCrossProjectSearchProvider);
      expect(state.query.pattern, 'next');
      expect(state.matches, isEmpty);
      expect(state.progressByProject, isEmpty);
      expect(state.isSearching, true);
    });

    test('appendMatch appends without dropping prior matches', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container
          .read(activeCrossProjectSearchProvider.notifier)
          .appendMatch(_match(projectId: 'a'));
      container
          .read(activeCrossProjectSearchProvider.notifier)
          .appendMatch(_match(projectId: 'b'));
      final state = container.read(activeCrossProjectSearchProvider);
      expect(state.matches, hasLength(2));
      expect(state.matches[0].projectId, 'a');
      expect(state.matches[1].projectId, 'b');
    });

    test('updateProgress overwrites the latest event per project', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container
          .read(activeCrossProjectSearchProvider.notifier)
          .updateProgress(
            const CrossProjectSearchProgress(
              projectId: 'p',
              projectName: 'P',
              status: CrossProjectSearchProgressStatus.searching,
            ),
          );
      container
          .read(activeCrossProjectSearchProvider.notifier)
          .updateProgress(
            const CrossProjectSearchProgress(
              projectId: 'p',
              projectName: 'P',
              status: CrossProjectSearchProgressStatus.completed,
              matchCount: 3,
            ),
          );
      final state = container.read(activeCrossProjectSearchProvider);
      expect(
        state.progressByProject['p']?.status,
        CrossProjectSearchProgressStatus.completed,
      );
      expect(state.progressByProject['p']?.matchCount, 3);
    });

    test('completeSearch clears busy flag but preserves matches', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container
          .read(activeCrossProjectSearchProvider.notifier)
          .startSearch(
            const CrossProjectSearchQuery(pattern: 'foo'),
          );
      container
          .read(activeCrossProjectSearchProvider.notifier)
          .appendMatch(_match());
      container
          .read(activeCrossProjectSearchProvider.notifier)
          .completeSearch();
      final state = container.read(activeCrossProjectSearchProvider);
      expect(state.isSearching, false);
      expect(state.matches, hasLength(1));
    });

    test('reset returns to idle from any state', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container
          .read(activeCrossProjectSearchProvider.notifier)
          .startSearch(
            const CrossProjectSearchQuery(pattern: 'x'),
          );
      container
          .read(activeCrossProjectSearchProvider.notifier)
          .appendMatch(_match());
      container.read(activeCrossProjectSearchProvider.notifier).reset();
      final state = container.read(activeCrossProjectSearchProvider);
      expect(state.query.pattern, '');
      expect(state.matches, isEmpty);
      expect(state.isSearching, false);
    });
  });
}

CrossProjectSearchMatch _match({String projectId = 'p'}) {
  return CrossProjectSearchMatch(
    projectId: projectId,
    projectName: 'Proj $projectId',
    matchKind: CrossProjectSearchMatchKind.testName,
    matchedText: 'foo',
    contextSnippet: 'foo',
    target: const CrossProjectSearchTestTarget(testId: 'foo'),
  );
}

class _FakeService implements CrossProjectSearchService {
  @override
  Stream<CrossProjectSearchMatch> search(CrossProjectSearchQuery query) {
    return const Stream<CrossProjectSearchMatch>.empty();
  }

  @override
  Stream<CrossProjectSearchProgress> get progress =>
      const Stream<CrossProjectSearchProgress>.empty();

  @override
  Future<void> cancelActiveSearch() async {}
}
