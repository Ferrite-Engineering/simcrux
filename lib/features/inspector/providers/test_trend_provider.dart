// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show FutureProviderFamily;
import 'package:meta/meta.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/trend_store.dart';
import 'package:simcrux/services/trend_store/trend_store_provider.dart';

/// Coalescing window for [trendStoreChangeTickProvider]. Every tick
/// re-runs the full SQLite query behind each open sparkline / delta
/// strip, so a burst of `dataChanged` events (e.g. several batched
/// trend flushes landing close together) is throttled to at most one
/// tick per window: the first event ticks immediately (small runs stay
/// snappy), the rest of the burst coalesces into one trailing tick.
const Duration kTrendTickCoalesceWindow = Duration(milliseconds: 250);

/// Leading-plus-trailing throttle over a change stream: an event
/// outside the window is forwarded immediately; events inside the
/// window collapse into a single trailing emission when it closes (so
/// the final state of a burst is never dropped — including a burst cut
/// short by the source closing). At most ~one emission per [window]
/// under sustained load, and no starvation.
@visibleForTesting
Stream<void> coalesceTrendTicks(
  Stream<void> source, {
  Duration window = kTrendTickCoalesceWindow,
}) {
  final controller = StreamController<void>();
  StreamSubscription<void>? sub;
  Timer? timer;
  var pendingTrailing = false;

  void onEvent() {
    if (timer != null) {
      pendingTrailing = true;
      return;
    }
    controller.add(null);
    timer = Timer(window, () {
      timer = null;
      if (pendingTrailing) {
        pendingTrailing = false;
        onEvent();
      }
    });
  }

  controller
    ..onListen = () {
      sub = source.listen(
        (_) => onEvent(),
        onError: controller.addError,
        onDone: () {
          // Don't lose a trailing tick pending behind the window.
          if (pendingTrailing) controller.add(null);
          timer?.cancel();
          unawaited(controller.close());
        },
      );
    }
    ..onCancel = () {
      timer?.cancel();
      return sub?.cancel();
    };
  return controller.stream;
}

/// Monotonically-incrementing tick that increments when the active
/// [TrendStore] reports `dataChanged` events — throttled through
/// [coalesceTrendTicks] so a burst of mutations costs one refetch per
/// [kTrendTickCoalesceWindow], not one per event. Trend-consuming
/// providers `ref.watch` this so each ingestion / pruning forces an
/// automatic refetch — no manual `ref.invalidate` required.
///
/// Why this is necessary: under the Pro per-project provider scope,
/// the [TrendStore]-reading `FutureProvider`s below are NOT overridden
/// in the per-tab container — they materialize at the root. The
/// per-tab [RegressionRunner]'s `ref.invalidate` call cannot reach
/// that root-cached element from a child container in Riverpod, so
/// the inspector kept rendering the stale snapshot it first cached.
/// Listening to the store's broadcast stream of mutations bypasses
/// the cross-container invalidation problem entirely: the tick lives
/// at root alongside the FutureProviders that depend on it.
final StreamProvider<int> trendStoreChangeTickProvider = StreamProvider<int>((
  ref,
) async* {
  yield 0;
  final TrendStore store;
  try {
    store = await ref.watch(trendStoreProvider.future);
  } on Object {
    return;
  }
  var tick = 0;
  await for (final _ in coalesceTrendTicks(store.dataChanged)) {
    yield ++tick;
  }
});

/// The last ten terminal statuses for a single test (the
/// [TrendStore.recentTrend] default), most recent first. Backed by the
/// persistent SQLite [TrendStore].
///
/// Watches [trendStoreChangeTickProvider] so each new trend point
/// causes the future to re-fetch and the inspector's sparkline to
/// re-render with the latest history.
final FutureProviderFamily<List<TestStatus>, String> testTrendProvider =
    FutureProvider.family<List<TestStatus>, String>(
      (ref, testId) async {
        ref.watch(trendStoreChangeTickProvider);
        final TrendStore store;
        try {
          store = await ref.watch(trendStoreProvider.future);
        } on Object {
          return const <TestStatus>[];
        }
        final out = <TestStatus>[];
        await for (final point in store.recentTrend(testId)) {
          out.add(point.status);
        }
        return out;
      },
    );

/// Run-over-run status deltas across the most recent runs. Reads the
/// store's `recentDeltas` stream; used by the dashboard's
/// "recently-changed-status" sub-section.
///
/// Same auto-refresh rationale as [testTrendProvider] — watches
/// [trendStoreChangeTickProvider] so ingestions / prunings re-trigger
/// the dashboard's recently-changed-status section without manual
/// invalidation.
final FutureProvider<List<TrendDelta>> recentTrendDeltasProvider =
    FutureProvider<List<TrendDelta>>(
      (ref) async {
        ref.watch(trendStoreChangeTickProvider);
        final TrendStore store;
        try {
          store = await ref.watch(trendStoreProvider.future);
        } on Object {
          return const <TrendDelta>[];
        }
        final deltas = <TrendDelta>[];
        // Linter wants forEach + tear-off, but the body is an async-for
        // over a Stream — tear-off doesn't compose with `await for`, so
        // the loop is the right tool here.
        // ignore: prefer_foreach
        await for (final delta in store.recentDeltas()) {
          deltas.add(delta);
        }
        return deltas;
      },
    );
