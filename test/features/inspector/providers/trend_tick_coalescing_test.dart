// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/inspector/providers/test_trend_provider.dart';

/// [coalesceTrendTicks] guards the sparkline/delta-strip refetch cost:
/// every forwarded tick re-runs the full SQLite query behind each open
/// trend surface, so a burst of `dataChanged` events must collapse to
/// leading + trailing emissions instead of one query per event.
///
/// **The two cases that wait out a coalescing window run under [fakeAsync];
/// the two that only assert event ordering stay on real async.** That split
/// is deliberate:
///
/// * A window wait cannot be polled. `pollUntil` says so itself — checking a
///   condition faster than a real `Timer` does not make the timer fire any
///   sooner. The old shape here slept `window + 20 ms` on the wall clock and
///   asserted that the trailing emission had landed, which is a bet that
///   20 ms of slack beats the scheduler. Under load it lost, reporting one
///   emission where two were expected. `fakeAsync` advances the window's own
///   clock, so "one window has elapsed" becomes a fact rather than a wager —
///   and the boundary can be asserted exactly, one millisecond either side.
///   No production seam was needed: [coalesceTrendTicks] already takes its
///   window as a parameter and builds its `Timer` in the ambient zone, which
///   `fakeAsync` controls.
/// * The ordering cases (`close` flushing a pending tick, `cancel` tearing
///   down the source) never wait out a window — they yield with
///   `Duration.zero`, and microtask ordering is not load-dependent, so there
///   is nothing to race. They must also *stay* on real async: those two
///   exercise the path where the outer controller's `onCancel` returns the
///   source subscription's cancel future, and under `fakeAsync` that future
///   never completes when the cancel originates inside the source's own done
///   delivery. The outer stream closes but its `onDone` never fires — a
///   fake-clock artifact, verified absent on real async, and precisely the
///   path these two cases exist to check. Faking the clock there would test
///   the fake instead of the code.
void main() {
  const window = Duration(milliseconds: 40);

  /// Yields the real event loop once. Enough for microtask-ordered stream
  /// delivery; deliberately not a window wait.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('a burst collapses to a leading and one trailing emission', () {
    fakeAsync((async) {
      final source = StreamController<void>();
      var emissions = 0;
      final sub = coalesceTrendTicks(
        source.stream,
        window: window,
      ).listen((_) => emissions++);

      for (var i = 0; i < 20; i++) {
        source.add(null);
      }
      async.flushMicrotasks();
      expect(emissions, 1, reason: 'leading edge forwards immediately');

      // One millisecond short of the window: the trailing emission is still
      // pending. A wall-clock test cannot assert this half at all.
      async
        ..elapse(window - const Duration(milliseconds: 1))
        ..flushMicrotasks();
      expect(emissions, 1, reason: 'the window has not closed yet');

      async
        ..elapse(const Duration(milliseconds: 1))
        ..flushMicrotasks();
      expect(
        emissions,
        2,
        reason: '19 burst events collapse into one trailing emission',
      );

      unawaited(sub.cancel());
      async.flushMicrotasks();
    });
  });

  test('events spaced beyond the window each forward', () {
    fakeAsync((async) {
      final source = StreamController<void>();
      var emissions = 0;
      final sub = coalesceTrendTicks(
        source.stream,
        window: window,
      ).listen((_) => emissions++);

      for (var i = 0; i < 3; i++) {
        source.add(null);
        async
          ..flushMicrotasks()
          ..elapse(window + const Duration(milliseconds: 1))
          ..flushMicrotasks();
      }
      expect(emissions, 3);

      unawaited(sub.cancel());
      async.flushMicrotasks();
    });
  });

  test('source closing flushes a pending trailing tick, then closes', () async {
    final source = StreamController<void>();
    var emissions = 0;
    var done = false;
    final sub = coalesceTrendTicks(source.stream, window: window).listen(
      (_) => emissions++,
      onDone: () => done = true,
    );
    addTearDown(sub.cancel);

    source
      ..add(null)
      ..add(null); // second event is pending behind the window
    await settle();
    expect(emissions, 1, reason: 'only the leading edge so far');

    await source.close();
    await settle();

    expect(emissions, 2, reason: 'the pending trailing tick must not be lost');
    expect(done, isTrue);
  });

  test('cancelling the subscription cancels the source and timer', () async {
    final source = StreamController<void>();
    addTearDown(source.close);
    final sub = coalesceTrendTicks(
      source.stream,
      window: window,
    ).listen((_) {});
    source.add(null);
    await settle();
    await sub.cancel();
    expect(source.hasListener, isFalse);
  });
}
