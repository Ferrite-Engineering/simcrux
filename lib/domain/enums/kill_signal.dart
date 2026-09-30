// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// The terminal OS signal the scheduler/reaper delivered to a test's
/// process tree when it was cancelled or timed out.
///
/// Surfaced on `TestExecutionFinished` and `TestResult` (and into the
/// streaming `results.ndjson`) so the recorded outcome encodes the
/// *kill path* — not just the *kill outcome*. A clean run that exits on
/// its own carries `null` (no signal was ever sent); a run that exits on
/// the initial SIGTERM carries [sigterm]; a run that ignored SIGTERM and
/// had to be escalated carries [sigkill]. The robustness corpus
/// (`test/fixtures/orchestration/`) pins this so a regression that
/// silently drops the SIGKILL escalation is caught by the golden.
enum KillSignal {
  /// Graceful termination request (POSIX `SIGTERM`). The reaper sends
  /// this first to every member of the process group.
  sigterm,

  /// Forced kill (POSIX `SIGKILL`). The reaper escalates to this when a
  /// process tree is still alive after the grace window following
  /// [sigterm].
  sigkill;

  /// The uppercase wire label used in the streaming `results.ndjson`
  /// golden (`"SIGTERM"` / `"SIGKILL"`).
  String get wireName => switch (this) {
    KillSignal.sigterm => 'SIGTERM',
    KillSignal.sigkill => 'SIGKILL',
  };

  /// Parses a [wireName] back to a [KillSignal], or null for an absent /
  /// unrecognized value (so an older `results.ndjson` without the field
  /// decodes to "no signal sent").
  static KillSignal? fromWireName(Object? value) => switch (value) {
    'SIGTERM' => KillSignal.sigterm,
    'SIGKILL' => KillSignal.sigkill,
    _ => null,
  };
}
