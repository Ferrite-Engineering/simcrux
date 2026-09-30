// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// Waveform dump format produced by a simulator.
///
/// SimCrux speaks the same format set as WaveCrux: VCD, FST, GHW.
/// The `cocotb` simulator forwards to its backend's native format
/// (GHDL → GHW; Icarus/Verilator → VCD or FST).
enum WaveformFormat {
  /// Value Change Dump — IEEE 1800-2023 standard. ASCII-based,
  /// universally supported, slow at scale.
  vcd,

  /// Fast Signal Trace — GTKWave's binary format. Compact and fast.
  /// SimCrux's default for Icarus and Verilator.
  fst,

  /// GHDL Waveform — GHDL's native nine-state format. The default
  /// for the GHDL driver; convertible to FST via `vcd2fst`.
  ghw,
}
