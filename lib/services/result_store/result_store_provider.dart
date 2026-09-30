// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/interfaces/result_store.dart';
import 'package:simcrux/services/result_store/in_memory_result_store.dart';

/// The currently-active [ResultStore].
///
/// A single nullable slot: the dashboard creates an
/// [InMemoryResultStore] when the user kicks off a regression and
/// publishes it here so every panel (results table, status bar,
/// trend mini-view) can subscribe to `currentRun` without threading
/// a controller through the widget tree.
///
/// The surface is deliberately minimal so downstream consumers wire up
/// against one provider.
final NotifierProvider<ResultStoreNotifier, ResultStore?> resultStoreProvider =
    NotifierProvider<ResultStoreNotifier, ResultStore?>(
      ResultStoreNotifier.new,
    );

/// Notifier backing [resultStoreProvider]. Starts in the null
/// (no-active-run) state. The dashboard sets a fresh store at run
/// start via [setStore] and clears it via [clear].
class ResultStoreNotifier extends Notifier<ResultStore?> {
  @override
  ResultStore? build() => null;

  /// Publishes [store] as the active store, returning it for chaining.
  /// Replacing an existing store does **not** close the previous one
  /// — the caller is responsible for calling `recordRunCompletion`
  /// (or its equivalent) on the previous store before swapping it out.
  T publish<T extends ResultStore>(T store) {
    state = store;
    return store;
  }

  /// Clears the active store. Used when the user closes a project or
  /// after a run completes and the dashboard returns to an idle
  /// state.
  void clear() {
    state = null;
  }
}
