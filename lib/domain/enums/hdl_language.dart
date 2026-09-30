// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// HDL languages SimCrux is aware of.
///
/// Used by `SimulatorCapabilities.supportedLanguages` and by the
/// configuration loader to route a source file to the appropriate
/// simulator (Verilog/SystemVerilog → Icarus / Verilator; VHDL → GHDL;
/// Cocotb Python is `python` because it is a wrapper around an
/// underlying HDL simulator).
enum HdlLanguage {
  /// Verilog (IEEE 1364).
  verilog,

  /// SystemVerilog (IEEE 1800).
  systemVerilog,

  /// VHDL (IEEE 1076).
  vhdl,

  /// Mixed-language designs (Verilog + VHDL in one project).
  mixed,

  /// Python testbenches via Cocotb. Routed to an underlying HDL
  /// simulator (Icarus, Verilator, GHDL) configured via
  /// `cocotb.simulator_backend`.
  python,
}
