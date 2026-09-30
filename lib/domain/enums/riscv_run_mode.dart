// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// How the `riscv_arch` driver obtains the two signatures it compares.
///
/// Declared in the `riscv:` block as `mode:`. **Never environment-gated**:
/// an env-var-selected *separate driver*
/// — the `SIMCRUX_DEMO_RUNNER` / `DemoSimulatorDriver` pattern — would make
/// CI exercise a different code path than production, which is the single
/// thing demo mode must not do. Every mode below runs through the same
/// driver, the same signature reading, the same [GoldenComparator] call,
/// the same metric emission and the same event construction. Modes differ
/// **only** in which subprocesses get spawned.
enum RiscvRunMode {
  /// SimCrux owns the whole flow: cross-compile the architectural test,
  /// run the reference model to produce the golden signature, run the DUT
  /// to produce its signature, compare.
  ///
  /// Requires the full toolchain. This is the default.
  normal('normal'),

  /// No subprocess is spawned at all. Both signatures are staged from a
  /// committed corpus of pre-captured pairs and then compared through the
  /// identical downstream path.
  ///
  /// This is simultaneously the offline-demo path (a conference laptop, a
  /// reviewer's first ten minutes) and the CI test path (GitHub Actions
  /// runners have no RISC-V cross-compiler and no reference model). Not a
  /// convenience: it is how this driver is tested at all.
  ///
  /// **No toolchain probe fires in demo mode.** The probe is skipped, not
  /// run-and-tolerated — there is nothing to probe for and a missing
  /// component is not a defect here.
  demo('demo'),

  /// Hand the per-test job to the user's existing RISCOF flow and read
  /// back the two signatures it leaves behind.
  ///
  /// **A deliberate second-class path.** Shelling RISCOF once for
  /// the whole suite was *rejected* as the primary design because it
  /// forfeits per-test scheduling, per-test timeouts, cancellation and
  /// progress — the dashboard would show one row that either passed or
  /// failed for twenty minutes. This mode keeps SimCrux's one-job-per-test
  /// scheduling and simply delegates the *work* of one test, so the
  /// configured command is spawned **once per test**: point it at a single
  /// test (RISCOF's `--testfile`) rather than at the whole suite.
  /// Cancellation and the timeout apply to the invocation, not to any
  /// internal RISCOF test loop.
  riscofPassthrough('riscof_passthrough');

  const RiscvRunMode(this.wireName);

  /// Stable token used in `simcrux.yaml`. Never localize or reformat it —
  /// it lands in user config files.
  final String wireName;

  /// Parses a [wireName] back to its enum value, or null when unknown.
  static RiscvRunMode? fromWireName(Object? raw) {
    if (raw is! String) return null;
    for (final mode in RiscvRunMode.values) {
      if (mode.wireName == raw) return mode;
    }
    return null;
  }

  /// Every mode token, in declaration order — used to render loader
  /// diagnostics that enumerate the valid values.
  static List<String> get wireNames =>
      RiscvRunMode.values.map((m) => m.wireName).toList();
}
