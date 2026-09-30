// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/resource_lock.dart';
import 'package:simcrux/services/job_scheduler/resource_lock_table.dart';

ResourceLock _lock(String name) => ResourceLock(name: name);

void main() {
  group('ResourceLockTable', () {
    test('grants an uncontended lock immediately', () async {
      final table = ResourceLockTable();
      await table.acquire(_lock('board-a'));
      expect(table.isHeld('board-a'), isTrue);
      expect(table.waiterCount('board-a'), 0);
    });

    test('queues a second acquirer until release', () async {
      final table = ResourceLockTable();
      await table.acquire(_lock('board-a'));

      var secondGranted = false;
      unawaited(
        table.acquire(_lock('board-a')).then((_) => secondGranted = true),
      );
      await pumpMicrotasks();
      expect(
        secondGranted,
        isFalse,
        reason: 'the lock is held; the second acquirer must wait',
      );

      table.release(<ResourceLock>[_lock('board-a')]);
      await pumpMicrotasks();
      expect(secondGranted, isTrue);
    });

    test(
      'an acquire interleaved between release and the waiter resuming '
      'does not double-grant',
      () async {
        // The double-grant race: `release` used to clear the held entry
        // and complete the waiter's completer. The waiter only re-adds
        // the entry when its microtask resumes — so any `acquire` that
        // runs in that window observed the lock as free and was granted
        // it alongside the waiter. Two holders of one FPGA board.
        final table = ResourceLockTable();
        await table.acquire(_lock('board-a'));

        final grantOrder = <String>[];
        unawaited(
          table.acquire(_lock('board-a')).then((_) => grantOrder.add('waiter')),
        );
        await pumpMicrotasks();
        expect(table.waiterCount('board-a'), 1);

        // Release, then synchronously — before yielding to the
        // microtask queue, which is exactly the interleaving the bug
        // needed — attempt a third acquisition.
        table.release(<ResourceLock>[_lock('board-a')]);
        var interloperGranted = false;
        unawaited(
          table.acquire(_lock('board-a')).then((_) {
            interloperGranted = true;
            grantOrder.add('interloper');
          }),
        );

        await pumpMicrotasks();

        expect(
          grantOrder,
          <String>['waiter'],
          reason: 'ownership transfers to the FIFO waiter only',
        );
        expect(
          interloperGranted,
          isFalse,
          reason:
              'the interloper must observe the lock as held — ownership '
              'was transferred, never momentarily released',
        );
        expect(table.isHeld('board-a'), isTrue);
        expect(table.waiterCount('board-a'), 1);

        // And the interloper is granted once the waiter itself releases.
        table.release(<ResourceLock>[_lock('board-a')]);
        await pumpMicrotasks();
        expect(interloperGranted, isTrue);
        expect(grantOrder, <String>['waiter', 'interloper']);
      },
    );

    test('releases fully when no waiter is queued', () async {
      final table = ResourceLockTable();
      await table.acquire(_lock('board-a'));
      table.release(<ResourceLock>[_lock('board-a')]);
      expect(table.isHeld('board-a'), isFalse);
      expect(table.held, isEmpty);
    });

    test('grants waiters in FIFO order', () async {
      final table = ResourceLockTable();
      await table.acquire(_lock('slot'));
      final order = <int>[];
      for (var i = 0; i < 3; i++) {
        unawaited(table.acquire(_lock('slot')).then((_) => order.add(i)));
        await pumpMicrotasks();
      }
      for (var i = 0; i < 3; i++) {
        table.release(<ResourceLock>[_lock('slot')]);
        await pumpMicrotasks();
      }
      expect(order, <int>[0, 1, 2]);
    });

    test('release of an unheld lock is a no-op', () {
      final table = ResourceLockTable();
      expect(
        () => table.release(<ResourceLock>[_lock('never-held')]),
        returnsNormally,
      );
      expect(table.held, isEmpty);
    });
  });
}

/// Drains the microtask queue so pending `then` callbacks run.
Future<void> pumpMicrotasks() => Future<void>.delayed(Duration.zero);
