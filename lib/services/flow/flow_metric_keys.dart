// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// The `TestResult.metrics` keys a flow result carries.
///
/// Enough for the dashboard row and the JSON and JUnit exporters; the full
/// metric set goes to the trend store's `flow_metrics` table. Verdict tokens
/// and metric keys are never translated.
abstract final class FlowMetricKeys {
  /// `librelane` or `nextpnr`.
  static const String kind = 'flow.kind';

  /// The `FlowVerdict` wire name. The scheduler's final status follows it:
  /// `met` passes, everything else fails.
  static const String verdict = 'flow.verdict';

  /// The run directory, absolute: LibreLane's `runs/<tag>/`, or the
  /// directory SimCrux gave a nextpnr run.
  static const String runDir = 'flow.run_dir';

  /// Which reader produced the verdict ([FlowReaderIds]).
  static const String reader = 'flow.reader';

  /// `true` when the reader is verified against the run's tool version,
  /// `false` when it read the run best-effort.
  static const String readerVerified = 'flow.reader_verified';

  /// Worst setup slack in integer picoseconds, when the run has one.
  static const String wnsPs = 'flow.wns_ps';

  /// Lowest achieved clock frequency in MHz (nextpnr).
  static const String fmaxMhz = 'flow.fmax_mhz';

  /// The step a stopped run stopped at.
  static const String stoppedStep = 'flow.stopped_step';

  /// The run tag (`simcrux-20261021T120000Z`).
  static const String tag = 'flow.tag';

  /// The closed telemetry target token (`ice40`, `sky130`, `other`, ...).
  static const String target = 'flow.target';

  /// How many steps the run directory records.
  static const String steps = 'flow.steps';

  /// What the reader could not read, verbatim, when the verdict is not one
  /// the run itself stated.
  static const String readerProblem = 'flow.reader_problem';

  /// Why the reader is not verified for this run: `version_unknown`,
  /// `layout_unknown` or `schema_unknown`.
  static const String readerUnsupported = 'flow.reader_unsupported';

  /// The process exit code. Recorded, never the verdict.
  static const String processExitCode = 'flow.process_exit_code';

  /// How the WNS of a nextpnr run was derived.
  static const String wnsDerivation = 'flow.wns_derivation';
}

/// The reader ids [FlowMetricKeys.reader] takes.
abstract final class FlowReaderIds {
  /// nextpnr's `--report` JSON.
  static const String nextpnrReport = 'nextpnr_report';

  /// nextpnr's log, for runs without a report (FuseSoC's Edalize default).
  static const String nextpnrLog = 'nextpnr_log';

  /// crux_flow's versioned LibreLane run readers: verified for the releases
  /// each reader's range names, best-effort for any other.
  static const String librelane = 'librelane_run';
}

/// How the WNS of a nextpnr run is derived, as `--json` names it.
const String kNextpnrWnsDerivation =
    'per clock 1000/constraint_mhz - 1000/achieved_mhz ns (period slack); '
    'the minimum over clocks';
