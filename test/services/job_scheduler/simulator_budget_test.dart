// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/services/job_scheduler/simulator_budget.dart';

void main() {
  group('SimulatorBudget', () {
    test('hands out permits up to the limit, then queues FIFO', () async {
      final budget = SimulatorBudget(limit: 2);
      await budget.acquire();
      await budget.acquire();
      expect(budget.inUse, 2);

      var thirdDone = false;
      var fourthDone = false;
      unawaited(budget.acquire().then((_) => thirdDone = true));
      unawaited(budget.acquire().then((_) => fourthDone = true));
      await Future<void>.delayed(Duration.zero);
      expect(budget.queueLength, 2);
      expect(thirdDone, isFalse);

      budget.release();
      await Future<void>.delayed(Duration.zero);
      expect(thirdDone, isTrue, reason: 'the oldest waiter goes first');
      expect(fourthDone, isFalse);
      expect(budget.inUse, 2);
    });

    test(
      'raising the limit wakes waiters; lowering it drains naturally',
      () async {
        final budget = SimulatorBudget(limit: 1);
        await budget.acquire();
        var secondDone = false;
        unawaited(budget.acquire().then((_) => secondDone = true));
        await Future<void>.delayed(Duration.zero);
        expect(secondDone, isFalse);

        budget.limit = 2;
        await Future<void>.delayed(Duration.zero);
        expect(secondDone, isTrue, reason: 'Settings raised the budget');
        expect(budget.inUse, 2);

        // Lowered below what is in use: nothing is cancelled, and the next
        // acquire waits until the count is back under the new limit.
        budget.limit = 1;
        var thirdDone = false;
        unawaited(budget.acquire().then((_) => thirdDone = true));
        budget.release();
        await Future<void>.delayed(Duration.zero);
        expect(thirdDone, isFalse, reason: 'still one in use, limit is one');
        budget.release();
        await Future<void>.delayed(Duration.zero);
        expect(thirdDone, isTrue);
        expect(budget.inUse, 1);
      },
    );

    test('a limit below one is refused', () {
      expect(() => SimulatorBudget(limit: 0), throwsArgumentError);
      expect(() => SimulatorBudget().limit = 0, throwsArgumentError);
    });

    test('the provider is one shared budget at the default limit', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final budget = container.read(simulatorBudgetProvider);
      expect(budget.limit, kDefaultSimulatorBudget);
      expect(container.read(simulatorBudgetProvider), same(budget));
    });
  });
}
