// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/services/job_scheduler/semaphore.dart';

void main() {
  group('Semaphore', () {
    test('admits up to maxConcurrent without blocking', () async {
      final sem = Semaphore(2);
      await sem.acquire();
      await sem.acquire();
      expect(sem.inUse, equals(2));
    });

    test('queues additional acquires FIFO', () async {
      final sem = Semaphore(1);
      await sem.acquire();
      expect(sem.queueLength, equals(0));

      final waiterA = sem.acquire();
      final waiterB = sem.acquire();
      expect(sem.queueLength, equals(2));

      sem.release();
      await waiterA;
      expect(sem.queueLength, equals(1));

      sem.release();
      await waiterB;
      expect(sem.queueLength, equals(0));
    });

    test('throws when release is called with no permits in use', () async {
      final sem = Semaphore(1);
      expect(sem.release, throwsA(isA<AssertionError>()));
    });

    test('withPermit acquires and releases automatically', () async {
      final sem = Semaphore(1);
      final result = await sem.withPermit<int>(() async => 42);
      expect(result, equals(42));
      expect(sem.inUse, equals(0));
    });

    test('withPermit releases on exception', () async {
      final sem = Semaphore(1);
      await expectLater(
        sem.withPermit<int>(() async => throw StateError('boom')),
        throwsStateError,
      );
      expect(sem.inUse, equals(0));
    });

    test('bounds true concurrency under parallel callers', () async {
      final sem = Semaphore(3);
      var concurrent = 0;
      var peak = 0;
      Future<void> body() async {
        await sem.acquire();
        concurrent++;
        if (concurrent > peak) peak = concurrent;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        concurrent--;
        sem.release();
      }

      await Future.wait(List.generate(10, (_) => body()));
      expect(peak, lessThanOrEqualTo(3));
      expect(peak, greaterThan(0));
    });
  });
}
