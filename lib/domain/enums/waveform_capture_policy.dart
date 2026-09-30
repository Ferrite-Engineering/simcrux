// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// When to capture a waveform dump from a test run.
///
/// Configured per-test or per-suite via `WaveformPolicy.capture`.
/// The default is `onFailure`: capturing always is expensive in disk
/// and simulator time; capturing never makes debugging a failure
/// impossible. Capturing on failure is the regression-runner default
/// shared with VCS and Questa configurations.
enum WaveformCapturePolicy {
  /// Always capture a waveform.
  always,

  /// Capture only when the test fails (per the pass/fail detector).
  onFailure,

  /// Capture only when the user explicitly re-runs the test with a
  /// "force waveform" flag. The inspector pane exposes a
  /// "Re-run with waveform forced" button that flips this case.
  onDemand,

  /// Never capture.
  never,
}
