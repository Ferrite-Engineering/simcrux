// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:simcrux/domain/models/resource_lock.dart';

/// FIFO mutual-exclusion table for named [ResourceLock]s within one
/// regression run.
///
/// A resource lock names something there is exactly one of — an FPGA
/// board on the bench, a floating simulator-license slot, a serial
/// port. Granting one twice does not merely slow the run down; it
/// produces two tests driving the same hardware and two sets of
/// meaningless results.
///
/// Ownership is transferred directly from the releasing holder to the
/// next waiter, never released and re-acquired. See [release] for why
/// the intermediate "unheld" state must not exist.
class ResourceLockTable {
  final Map<String, ResourceLock> _held = <String, ResourceLock>{};
  final Map<String, List<Completer<void>>> _waiters =
      <String, List<Completer<void>>>{};

  /// Currently-held locks by name. Unmodifiable snapshot.
  Map<String, ResourceLock> get held =>
      Map<String, ResourceLock>.unmodifiable(_held);

  /// True when [name] is held by someone.
  bool isHeld(String name) => _held.containsKey(name);

  /// Number of callers queued behind [name].
  int waiterCount(String name) => _waiters[name]?.length ?? 0;

  /// Acquires [lock], waiting in FIFO order when it is already held.
  Future<void> acquire(ResourceLock lock) {
    if (!_held.containsKey(lock.name)) {
      _held[lock.name] = lock;
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _waiters.putIfAbsent(lock.name, () => <Completer<void>>[]).add(completer);
    // Deliberately no `_held[lock.name] = lock` after the await: the
    // entry is already in place, put there on this waiter's behalf by
    // [release]. Re-asserting it here would be harmless, but relying on
    // it for correctness would not be — see [release].
    return completer.future;
  }

  /// Releases each lock in [locks], handing ownership to the next
  /// waiter when there is one.
  ///
  /// The held-entry is deliberately NOT cleared while a waiter exists.
  /// Clearing it and letting the woken waiter re-insert it on resume
  /// leaves the lock observably free for the duration of a microtask
  /// hop — long enough for an interleaved [acquire] to be granted the
  /// same board or license slot the waiter is about to receive.
  void release(Iterable<ResourceLock> locks) {
    for (final lock in locks) {
      final queue = _waiters[lock.name];
      if (queue != null && queue.isNotEmpty) {
        _held[lock.name] = lock;
        final next = queue.removeAt(0);
        if (queue.isEmpty) _waiters.remove(lock.name);
        next.complete();
      } else {
        _held.remove(lock.name);
        _waiters.remove(lock.name);
      }
    }
  }
}
