// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// The per-test result of a functional gate-level simulation.
///
/// Two verdicts are kept apart and folded here: the testbench's own (read as
/// SimCrux reads it at RTL) and the RTL-versus-gate comparison of the DUT's
/// top-level ports.
///
/// Display follows the flow rule: [xOnly] is a neutral note, and [differs] on
/// a completed run is a finding, never error red. Wire names are verdict
/// tokens and are never translated.
enum GlsOutcome {
  /// The testbench passes at gate level and no port differs.
  equal('equal'),

  /// Only X-asymmetry differs: the RTL was X or Z where the gates resolved to
  /// 0 or 1. Passes unless strict X is on; the count is always shown.
  xOnly('x_only'),

  /// The testbench fails at gate level, or a port is known on both sides and
  /// unequal, or the gate is X where the RTL is known.
  differs('differs'),

  /// The comparison could not be made; [GlsNotRunReason] says why.
  notRun('not_run');

  const GlsOutcome(this.wireName);

  /// The token in metrics, JSON, JUnit and telemetry.
  final String wireName;

  /// The outcome [wireName] names, or null.
  static GlsOutcome? fromWireName(String? wireName) {
    for (final value in values) {
      if (value.wireName == wireName) return value;
    }
    return null;
  }

  /// Whether this outcome passes the test: [equal], or [xOnly] when
  /// [strictX] is off.
  bool passes({required bool strictX}) => switch (this) {
    GlsOutcome.equal => true,
    GlsOutcome.xOnly => !strictX,
    GlsOutcome.differs || GlsOutcome.notRun => false,
  };
}

/// Why a test has no gate-level comparison.
enum GlsNotRunReason {
  /// The test fails at RTL, so a gate-level verdict would answer nothing.
  failsAtRtl('fails_at_rtl'),

  /// The test's RTL did not build for the gate-level comparison (under
  /// Icarus, the one simulator gate level uses).
  rtlBuildFailed('rtl_build_failed'),

  /// A VHDL (GHDL) test: the netlist is Verilog, and mixed-language gate
  /// level is out of scope.
  rtlLanguage('rtl_language'),

  /// The test runs under a simulator gate level does not use or rerun.
  simulatorUnsupported('simulator_unsupported'),

  /// The netlist's ports do not match the RTL top the testbench binds.
  portShape('port_shape'),

  /// The gate-level run did not build for a reason other than the ports.
  gateBuildFailed('gate_build_failed'),

  /// The cell models could not be found.
  modelsMissing('models_missing'),

  /// The run holds no netlist of the kind asked for.
  netlistMissing('netlist_missing'),

  /// The run's record could not be read.
  runUnreadable('run_unreadable'),

  /// None of the test's sources is a design source the run synthesised.
  noDesignSources('no_design_sources'),

  /// The testbench's instance of the design could not be found.
  dutScope('dut_scope'),

  /// No clock input could be found for the comparison to sample on.
  clockUnknown('clock_unknown'),

  /// More than one clock input; the entry names which one.
  clockAmbiguous('clock_ambiguous'),

  /// A port dump could not be read or is malformed.
  vcdUnreadable('vcd_unreadable'),

  /// A port dump is over the size cap.
  vcdTooLarge('vcd_too_large'),

  /// The clock never rose in the dumps, so nothing was sampled.
  noSamples('no_samples'),

  /// The simulator is not installed.
  toolMissing('tool_missing'),

  /// The test was cancelled.
  cancelled('cancelled');

  const GlsNotRunReason(this.wireName);

  /// The token in metrics, JSON and JUnit.
  final String wireName;

  /// The reason [wireName] names, or null.
  static GlsNotRunReason? fromWireName(String? wireName) {
    for (final value in values) {
      if (value.wireName == wireName) return value;
    }
    return null;
  }
}

/// The simulator gate-level simulation uses for a test whose RTL runs under
/// [rtlSimulatorId], or null when gate level does not apply to it.
///
/// **The one place a simulator is chosen.** Gate-level simulation is
/// Icarus-only: Verilator's two-state model turns an RTL X into 0, so a
/// Verilator comparison reports differences the four-state RTL means as X.
/// A Verilator test's gate-level request therefore reruns its RTL and its
/// gate run under Icarus, both. Everything else about the two runs (seed,
/// defines, parameters) is copied from the test, and the RTL and gate specs
/// are built from the same value of this function, so a comparison across two
/// simulators cannot be constructed: `$random(seed)` differs between
/// simulators, and a cross-simulator diff is noise.
String? glsSimulatorIdFor(String rtlSimulatorId) => switch (rtlSimulatorId) {
  'icarus' || 'verilator' => 'icarus',
  _ => null,
};
