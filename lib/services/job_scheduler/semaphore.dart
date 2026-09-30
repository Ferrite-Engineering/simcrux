// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:collection';

/// Fair (FIFO) counted semaphore.
///
/// `acquire` returns a future that completes when a permit is
/// available. `release` returns one permit to the pool and wakes the
/// next waiter, if any. The order is strict FIFO — `acquire` calls
/// are served in the order they were issued.
///
/// Used by [LocalJobScheduler] to bound concurrent test execution to
/// the configured max-parallel value.
class Semaphore {
  /// Creates a [Semaphore] with [maxConcurrent] permits available.
  Semaphore(this.maxConcurrent)
    : assert(maxConcurrent > 0, 'maxConcurrent must be positive');

  /// The fixed permit budget.
  final int maxConcurrent;

  int _inUse = 0;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  /// Permits currently held by callers.
  int get inUse => _inUse;

  /// Number of [acquire] futures currently pending.
  int get queueLength => _waiters.length;

  /// Acquire one permit. Completes immediately when a permit is
  /// available; otherwise queues FIFO behind earlier waiters.
  Future<void> acquire() async {
    if (_inUse < maxConcurrent) {
      _inUse++;
      return;
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    await completer.future;
  }

  /// Returns one permit to the pool. Wakes the oldest waiter if any.
  void release() {
    assert(_inUse > 0, 'release() called with no permits in use');
    if (_waiters.isNotEmpty) {
      // Hand the permit directly to the next waiter without bumping
      // the in-use count back down; the waiter inherits the slot.
      _waiters.removeFirst().complete();
      return;
    }
    _inUse--;
  }

  /// Convenience: run [action] under exactly one permit.
  Future<T> withPermit<T>(Future<T> Function() action) async {
    await acquire();
    try {
      return await action();
    } finally {
      release();
    }
  }
}
