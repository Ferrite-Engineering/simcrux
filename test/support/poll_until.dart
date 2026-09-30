// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

/// Bounded condition-poll for plain Dart / `ProviderContainer` unit
/// tests — the `test()`-body analog of the integration harness's
/// `pumpUntil` (`integration_test/helpers/app_driver.dart`).
///
/// Repeatedly checks [condition], yielding to the real event loop via
/// `Future.delayed` between checks, until it becomes true or [timeout]
/// elapses. Returns the final value of [condition] (`true` if it
/// converged, `false` if the timeout was hit) so callers can `expect`
/// on the result with a clear failure message rather than silently
/// racing ahead on an unmet condition.
///
/// Use this instead of a blind `Future.delayed` guess for a fixed
/// number of milliseconds whenever the wait is for something specific
/// to become observably true (an event list gaining an entry, a flag
/// flipping, a file appearing). It resolves as soon as the condition
/// holds — usually far faster than a worst-case-sized fixed delay —
/// and fails fast with a diagnosable timeout instead of a flaky
/// pass/fail split under load.
///
/// Not a fit for:
/// - Waits that are themselves the behavior under test (a debounce /
///   coalescing window, a heartbeat cadence) — polling faster than the
///   real timer doesn't shorten those. Reach for `package:fake_async`
///   there instead of a wall-clock sleep: advancing a fake clock by
///   exactly one window makes "the window has elapsed" a fact rather
///   than a bet on scheduling slack, and lets the test assert the other
///   half — that nothing has fired a millisecond early — which no
///   wall-clock test can check. `trend_tick_coalescing_test.dart` and
///   `inspector_log_provider_test.dart` are the worked examples; both
///   used to sleep `window + slack` and both went red under load.
/// - Deliberately unbounded fake/mock waits (e.g. "hang until an
///   explicit cancel flips a flag") — bounding those with a timeout
///   changes what's being simulated and can mask a broken cancel path.
Future<bool> pollUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  Duration interval = const Duration(milliseconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) return condition();
    await Future<void>.delayed(interval);
  }
  return true;
}
