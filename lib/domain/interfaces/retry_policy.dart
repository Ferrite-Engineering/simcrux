// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';

/// Per-test retry decision the scheduler consults after a failure.
///
/// Open-core ships [NoopRetryPolicy] as the default — no retries
/// regardless of failure. The Pro overlay overrides
/// `retryPolicyProvider` in `proOverrides` with `FlakyRetryPolicy`,
/// which consults the active flaky-detection scores and reruns
/// flaky-classified tests for up to `autoRetryAttempts` attempts
/// (`FlakinessConfig.autoRetryAttempts`).
///
/// **Lifecycle.** The scheduler invokes [shouldRetry] from inside its
/// per-test loop immediately after a non-passing result is recorded
/// and *before* the result is emitted to the run's [Stream]
/// downstream. If the policy returns true, the scheduler reruns the
/// test (with [nextSeedFor]'s seed when the spec did not pin one),
/// records the retry result, and decides again. Final result emitted
/// to the stream is the outcome of the last attempt; intermediate
/// retry attempts may be exposed as run-level metadata in a follow-up
/// once we have a UI consumer for the retry history.
///
/// **Why a policy interface and not a flag on the scheduler.** The
/// scheduler stays in open-core; the policy lives in either tier and
/// gets injected. Pro's policy reads the flaky-detection scores
/// (which themselves live in the Pro overlay); open-core never sees that
/// dependency. A future "retry every failure 3×" CI-mode policy can
/// land alongside the Pro one with no scheduler change.
abstract class RetryPolicy {
  /// Returns true if the test described by [spec] should be retried
  /// after producing [lastResult].
  ///
  /// [attemptsSoFar] counts every execution including the original
  /// (so the first call is `attemptsSoFar == 1`). [maxAttempts] is
  /// the policy-supplied upper bound — implementations may ignore it
  /// when they enforce their own cap, but the scheduler also enforces
  /// a hard scheduler-side ceiling so a buggy policy cannot loop
  /// indefinitely.
  bool shouldRetry({
    required TestSpec spec,
    required TestResult lastResult,
    required int attemptsSoFar,
    required int maxAttempts,
  });

  /// Returns the seed the scheduler should use for the *next* retry
  /// attempt of [spec], or null when the next attempt should not pin
  /// a seed (driver derives one).
  ///
  /// The default (no-op) policy returns null. The Pro
  /// [FlakyRetryPolicy] returns [lastResult.executionSeed] (or
  /// [spec.seed] when the executor did not echo back) for the first
  /// retry (deterministic replay) and a fresh random integer for
  /// subsequent retries (varied evidence). [attemptsSoFar] is the
  /// count of completed attempts so the first retry sees
  /// `attemptsSoFar == 1`.
  int? nextSeedFor({
    required TestSpec spec,
    required TestResult lastResult,
    required int attemptsSoFar,
  });
}

/// Optional run-lifecycle capability a [RetryPolicy] may implement when
/// its synchronous [RetryPolicy.shouldRetry] decision depends on state
/// that can only be loaded asynchronously (e.g. flaky-detection scores
/// read from a trend store).
///
/// The scheduler checks for this capability at run start and, when
/// present, `await`s [prepareForRun] with the full set of specs in the
/// run **before dispatching the first test**. This lets a policy warm
/// whatever cache its per-test decisions read from, so the very first
/// failure of the run sees a populated cache rather than a cold miss.
///
/// **Why a separate opt-in interface and not a method on [RetryPolicy].**
/// The base retry seam stays a pure sync decision — [NoopRetryPolicy]
/// and every other policy that needs no async priming (a hypothetical
/// "retry every failure 3× in CI" policy) are unaffected. Only policies
/// with async prerequisites — today just the Pro `FlakyRetryPolicy` —
/// implement this. Priming is best-effort: the scheduler swallows any
/// error from [prepareForRun] so a trend-store hiccup degrades to the
/// policy's cold-cache behavior (conservative "no retry") instead of
/// aborting the run.
abstract class PreparableRetryPolicy {
  /// Eagerly loads any async state the policy's [RetryPolicy.shouldRetry]
  /// decisions depend on for the tests in [specs]. Called once per run,
  /// before the first test executes.
  Future<void> prepareForRun(Iterable<TestSpec> specs);
}

/// Default no-op [RetryPolicy] — never retries.
///
/// Registered by the open-core `retryPolicyProvider`; replaced in the
/// Pro overlay by `FlakyRetryPolicy`.
class NoopRetryPolicy implements RetryPolicy {
  /// Const default.
  const NoopRetryPolicy();

  @override
  bool shouldRetry({
    required TestSpec spec,
    required TestResult lastResult,
    required int attemptsSoFar,
    required int maxAttempts,
  }) => false;

  @override
  int? nextSeedFor({
    required TestSpec spec,
    required TestResult lastResult,
    required int attemptsSoFar,
  }) => null;
}
