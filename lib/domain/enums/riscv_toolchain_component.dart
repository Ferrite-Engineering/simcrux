// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// One of the four independent dependencies an architectural-compatibility
/// (and, for [formalEngine], a formal) run needs on the host.
///
/// **Why an enum and not one `detectVersion` string.** `SimulatorDriver`'s
/// `detectVersion` returns a single `String?`, which is adequate for Icarus
/// and inadequate here: "not found" has a *different remediation* for each
/// of these, and on Windows two of them have no practical native answer at
/// all. `RiscvToolchainProbe` therefore reports per component and
/// `detectVersion` is implemented on top of it as a summary line.
enum RiscvToolchainComponent {
  /// The RISC-V GNU cross-compiler (`riscv{32,64}-unknown-elf-gcc`), used
  /// to build each architectural test into an ELF.
  crossCompiler('cross_compiler'),

  /// The golden reference model (Sail or Spike) that produces the
  /// signature the DUT is compared against.
  referenceModel('reference_model'),

  /// Python + the RISCOF framework. Needed only by
  /// `mode: riscof_passthrough`; the primary path drives the flow itself.
  pythonRiscof('python_riscof'),

  /// Yosys / SymbiYosys, the bounded-proof engine behind riscv-formal.
  ///
  /// Probed here rather than in a separate formal-driver probe so the diagnostics
  /// panel shows one coherent RISC-V toolchain picture. The `riscv_arch`
  /// driver never needs it and never fails on its absence.
  formalEngine('formal_engine');

  const RiscvToolchainComponent(this.wireName);

  /// Stable token used in metrics, logs and diagnostics output.
  final String wireName;
}
