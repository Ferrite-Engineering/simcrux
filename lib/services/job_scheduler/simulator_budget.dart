// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The process-wide simulator budget a fresh installation starts with: the
/// same number of slots one run has always had, so a single tab behaves
/// exactly as before and only a second concurrent regression notices.
const int kDefaultSimulatorBudget = 4;

/// The smallest budget Settings accepts.
const int kMinSimulatorBudget = 1;

/// The largest budget Settings accepts.
const int kMaxSimulatorBudget = 64;

/// How many simulator processes the whole app may run at once, across every
/// tab's regression.
///
/// Each run has always had its own permit pool (`RegressionRequest.concurrency`,
/// 4 in the app), so N tabs running regressions could spawn 4N simulators and
/// swamp a workstation. The budget is the pool every run's permits are drawn
/// from on top of its own: a test holds one of its run's permits *and* one of
/// these while it executes, so the per-run limit stays a sub-cap of the total.
///
/// A fair counted semaphore like `Semaphore`, with one difference: [limit] can
/// change while permits are held, because Settings edits it in a running app.
/// Raising it wakes waiters; lowering it lets the tests already running
/// finish and simply hands out nothing until the count is back under the new
/// limit. Nothing is ever cancelled by a budget change.
class SimulatorBudget {
  /// Creates a budget of [limit] simultaneous simulator processes.
  SimulatorBudget({int limit = kDefaultSimulatorBudget}) : _limit = limit {
    if (limit < 1) throw ArgumentError.value(limit, 'limit', 'must be >= 1');
  }

  int _limit;
  int _inUse = 0;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  /// The current cap. Setting it applies to the next permit handed out.
  int get limit => _limit;
  set limit(int next) {
    if (next < 1) throw ArgumentError.value(next, 'limit', 'must be >= 1');
    _limit = next;
    _wake();
  }

  /// Permits currently held.
  int get inUse => _inUse;

  /// Tests waiting for a permit, in order.
  int get queueLength => _waiters.length;

  /// Takes one permit, waiting FIFO behind earlier callers while the budget
  /// is spent.
  Future<void> acquire() {
    if (_inUse < _limit && _waiters.isEmpty) {
      _inUse++;
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  /// Returns one permit and wakes the next waiter the limit allows.
  void release() {
    assert(_inUse > 0, 'release() called with no permits in use');
    _inUse--;
    _wake();
  }

  void _wake() {
    while (_waiters.isNotEmpty && _inUse < _limit) {
      _inUse++;
      _waiters.removeFirst().complete();
    }
  }
}

/// The one [SimulatorBudget] every interactive run draws from.
///
/// Lives in the root container (nothing overrides it per tab), which is what
/// makes it shared. The limit starts at [kDefaultSimulatorBudget]; the
/// settings layer, which owns the user's value, sets `limit` when settings
/// load and whenever the user edits it (see `AppSettingsNotifier`). The
/// headless runner has one run per process and does not use it: there
/// `--max-parallel` is the total.
final Provider<SimulatorBudget> simulatorBudgetProvider =
    Provider<SimulatorBudget>(
      (_) => SimulatorBudget(),
      name: 'simulatorBudgetProvider',
    );
