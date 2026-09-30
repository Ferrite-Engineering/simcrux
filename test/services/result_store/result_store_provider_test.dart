// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/services/result_store/in_memory_result_store.dart';
import 'package:simcrux/services/result_store/result_store_provider.dart';

void main() {
  TestRun makeRun({String id = 'run-x'}) => TestRun(
    id: id,
    startedAt: DateTime.utc(2026, 5, 22),
    testIds: const <String>['s/t'],
  );

  group('resultStoreProvider', () {
    test('starts null', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(resultStoreProvider), isNull);
    });

    test('publish() sets and returns the store', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final store = InMemoryResultStore.forRun(makeRun());
      final returned = container
          .read(resultStoreProvider.notifier)
          .publish(store);

      expect(returned, same(store));
      expect(container.read(resultStoreProvider), same(store));
    });

    test('clear() resets to null', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final store = InMemoryResultStore.forRun(makeRun());
      final notifier = container.read(resultStoreProvider.notifier)
        ..publish(store);
      expect(container.read(resultStoreProvider), isNotNull);

      notifier.clear();
      expect(container.read(resultStoreProvider), isNull);
    });

    test('publishing a new store replaces (does not close) the prior one', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final a = InMemoryResultStore.forRun(makeRun(id: 'A'));
      final b = InMemoryResultStore.forRun(makeRun(id: 'B'));
      final notifier = container.read(resultStoreProvider.notifier)
        ..publish(a)
        ..publish(b);

      expect(container.read(resultStoreProvider), same(b));
      // Replacing didn't auto-complete the previous run.
      expect(a.isFinished, isFalse);
      notifier.clear();
    });
  });
}
