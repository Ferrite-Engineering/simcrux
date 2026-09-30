// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// Final classification of a single test run.
///
/// Used by `TestResult` and the dashboard's status filter chips.
/// Mirrors the universal CI / EDA convention shared with WaveCrux's
/// SVA assertion visualization (pass / fail / vacuous / cover /
/// running / skipped).
enum TestStatus {
  /// Test passed: detector classified the run as a success.
  pass,

  /// Test failed: detector classified the run as a failure (assertion
  /// fired, exit-code nonzero, expected string not seen, etc.).
  fail,

  /// Test passed vacuously: the assertion or property never enabled
  /// because its antecedent never held. Carries information distinct
  /// from a clean pass — vacuous passes flag broken testbench setup.
  vacuous,

  /// A coverage point was hit. Used by cover assertions and coverage
  /// counters that are reported as test results.
  cover,

  /// Test was running at the time the snapshot was taken. Used by the
  /// dashboard while tests are in flight.
  running,

  /// Test was skipped by configuration (e.g., not yet implemented,
  /// disabled by a tag filter, or excluded from the active suite).
  skipped,

  /// Test was killed by timeout. A subclass of `fail` in CI exit-code
  /// terms but retained as a distinct status so the dashboard can
  /// surface "timeout vs. assertion failure" separately.
  timeout,

  /// Test was cancelled by the user or by an upstream failure.
  cancelled,

  /// The result classifier could not determine pass/fail (e.g., the
  /// log was unparseable or the detector reported an error).
  unknown,
}
