// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// What caused a regression run to start.
///
/// Threaded through `RegressionRunner.start` / `submitSpecs` /
/// `startFromConfigPath` so the `regression.completed` counter can answer
/// "is anyone actually using auto-reload?" — a question no other signal in the
/// app answers, because an auto-reloaded run and a hand-started one are
/// otherwise identical by the time they reach the scheduler.
///
/// The trigger is also persisted: each run row in the trend store records
/// it in `runs.trigger_kind`, spelled as the value's name.
///
/// A plain enum rather than a set of bools: the causes are mutually
/// exclusive, and `telemetryEnumToken` turns each one into its own token
/// without a mapping table. Every name is already lowercase, so the
/// persisted spelling and the telemetry token are the same word.
enum RegressionTrigger {
  /// The user pressed Run, re-ran a test from the inspector, or opened a
  /// project with `autoRunOnOpen` enabled. The default, because every path
  /// that is not one of the two below is one the user initiated directly.
  manual,

  /// The file watcher re-ran the project after `simcrux.yaml` (or a watched
  /// source) changed on disk — `AutoReloadNotifier.rerun`.
  auto,

  /// A headless `simcrux --ci` invocation. Never reaches the GUI runner; the
  /// CI runner records with this trigger itself.
  ci,

  /// Results read from a run SimCrux did not launch: an existing
  /// implementation-flow run directory or report that the user ingested.
  ingest,

  /// A gate-level rerun of regression tests against a flow run's netlist.
  gls,
}
