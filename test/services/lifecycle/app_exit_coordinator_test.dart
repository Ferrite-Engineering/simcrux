// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/services/lifecycle/active_run_registry.dart';
import 'package:simcrux/services/lifecycle/app_exit_coordinator.dart';

void main() {
  group('ActiveRunRegistry', () {
    test('tracks registration and unregistration', () {
      final registry = ActiveRunRegistry();
      expect(registry.hasActiveRuns, isFalse);

      final token = registry.register(() async {});
      expect(registry.activeCount, 1);
      expect(registry.hasActiveRuns, isTrue);

      registry.unregister(token);
      expect(registry.activeCount, 0);
    });

    test('unregistering twice is a no-op', () {
      final registry = ActiveRunRegistry();
      final token = registry.register(() async {});
      registry
        ..unregister(token)
        ..unregister(token);
      expect(registry.activeCount, 0);
    });

    test(
      'cancelAll invokes every canceller and empties the registry',
      () async {
        final registry = ActiveRunRegistry();
        final cancelled = <String>[];
        registry
          ..register(() async => cancelled.add('a'))
          ..register(() async => cancelled.add('b'))
          ..register(() async => cancelled.add('c'));

        final settled = await registry.cancelAll();

        expect(settled, isTrue);
        expect(cancelled, unorderedEquals(<String>['a', 'b', 'c']));
        expect(registry.activeCount, 0);
      },
    );

    test('cancelAll on an empty registry settles immediately', () async {
      expect(await ActiveRunRegistry().cancelAll(), isTrue);
    });

    test('a throwing canceller does not stop the others', () async {
      final registry = ActiveRunRegistry();
      final cancelled = <String>[];
      registry
        ..register(() async => throw StateError('driver blew up'))
        ..register(() async => cancelled.add('survivor'));

      final settled = await registry.cancelAll();

      expect(settled, isTrue);
      expect(cancelled, <String>['survivor']);
    });

    test('cancelAll reports false when the grace budget expires', () async {
      final registry = ActiveRunRegistry();
      final hung = Completer<void>();
      registry.register(() => hung.future);

      final settled = await registry.cancelAll(
        grace: const Duration(milliseconds: 50),
      );

      expect(
        settled,
        isFalse,
        reason: 'a hung driver must time out, not block the caller forever',
      );
      expect(
        registry.activeCount,
        0,
        reason: 'the registry is drained regardless of the outcome',
      );
      hung.complete();
    });
  });

  group('AppExitCoordinator', () {
    test('shutdown cancels every in-flight run', () async {
      final registry = ActiveRunRegistry();
      var cancelCount = 0;
      registry
        ..register(() async => cancelCount++)
        ..register(() async => cancelCount++);
      final coordinator = AppExitCoordinator(registry: registry);

      expect(coordinator.isShuttingDown, isFalse);
      final settled = await coordinator.shutdown();

      expect(settled, isTrue);
      expect(cancelCount, 2);
      expect(coordinator.isShuttingDown, isTrue);
    });

    test('shutdown is idempotent', () async {
      final registry = ActiveRunRegistry();
      var cancelCount = 0;
      registry.register(() async => cancelCount++);
      final coordinator = AppExitCoordinator(registry: registry);

      await coordinator.shutdown();
      await coordinator.shutdown();

      expect(
        cancelCount,
        1,
        reason: 'a second quit request must not re-drain',
      );
    });

    test(
      'a concurrent second quit awaits the same drain, not an early true',
      () async {
        final registry = ActiveRunRegistry();
        final gate = Completer<void>();
        var cancelled = false;
        registry.register(() async {
          await gate.future;
          cancelled = true;
        });
        final coordinator = AppExitCoordinator(registry: registry);

        final first = coordinator.shutdown();
        final second = coordinator.shutdown();

        // The re-entrant quit must not resolve before the drain actually
        // reaped — returning an early `true` let the caller exit(0) with
        // cancellers not yet started (orphaning in-flight simulators).
        var secondDone = false;
        unawaited(second.then((_) => secondDone = true));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          secondDone,
          isFalse,
          reason: 'second quit must await the in-flight drain',
        );
        expect(cancelled, isFalse);

        gate.complete();
        expect(await first, isTrue);
        expect(await second, isTrue);
        expect(cancelled, isTrue);
      },
    );

    test(
      'shutdown returns false when a run outlives the grace budget',
      () async {
        final registry = ActiveRunRegistry();
        final hung = Completer<void>();
        registry.register(() => hung.future);
        final coordinator = AppExitCoordinator(
          registry: registry,
          grace: const Duration(milliseconds: 50),
        );

        expect(await coordinator.shutdown(), isFalse);
        hung.complete();
      },
    );

    test('shutdown with nothing running settles immediately', () async {
      final coordinator = AppExitCoordinator(registry: ActiveRunRegistry());
      expect(await coordinator.shutdown(), isTrue);
    });
  });
}
