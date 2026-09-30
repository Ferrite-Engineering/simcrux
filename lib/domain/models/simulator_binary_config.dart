// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

/// How SimCrux resolves the binary for a given simulator id.
///
/// **Nothing is bundled today.** `assets/sim_binaries/` does not exist and
/// no release ships a simulator. Every simulator resolves from `$PATH` or
/// from an explicit override.
///
/// That matters because [bundled] used to be the default, and the
/// not-available error names the resolution source: a user whose Icarus
/// simply was not installed got told SimCrux "could not invoke `iverilog`
/// via bundled resolution", which reads as *the copy we shipped you is
/// broken* and sends them looking in the wrong place. The default is now
/// [system], which is what actually happens.
enum SimulatorBinarySource {
  /// Use a SimCrux-bundled binary for this simulator.
  ///
  /// Reserved for per-platform release packaging. Until a release actually
  /// ships binaries this resolves identically to [system] — the driver
  /// treats both as "invoke the bare name and let the OS find it" — so
  /// selecting it changes nothing but the diagnostics wording.
  bundled,

  /// Resolve via `$PATH`. The effective default.
  system,

  /// Use the [SimulatorBinaryConfig.customPath] value verbatim.
  custom,
}

/// How a single simulator's binary is located and invoked.
///
/// Stored per simulator id (one entry per `icarus`, `verilator`,
/// `ghdl`, `cocotb`, …). The default at every key is
/// [SimulatorBinarySource.system] — nothing is bundled today, and
/// defaulting to `bundled` made a missing simulator report itself as a
/// broken bundled copy.
@immutable
class SimulatorBinaryConfig {
  /// Creates a [SimulatorBinaryConfig].
  const SimulatorBinaryConfig({
    required this.simulatorId,
    this.source = SimulatorBinarySource.system,
    this.customPath,
    this.extraEnv = const <String, String>{},
    this.options = const <String, String>{},
  });

  /// The simulator id this config applies to (e.g. `icarus`).
  final String simulatorId;

  /// How the binary is resolved. Defaults to [SimulatorBinarySource.system].
  final SimulatorBinarySource source;

  /// Path to the binary, used when [source] is
  /// [SimulatorBinarySource.custom]. Ignored otherwise.
  final String? customPath;

  /// Extra environment variables to inject when invoking the
  /// simulator (e.g. `XILINX_LIC_FILE`, `LM_LICENSE_FILE` for
  /// vendor simulators).
  final Map<String, String> extraEnv;

  /// Driver-specific options.
  ///
  /// Free-form key/value bag a [SimulatorDriver] implementation can
  /// consult for simulator-specific knobs that do not belong on the
  /// generic interface. Examples:
  ///
  /// - GHDL: `{ "backend": "llvm" }` selects the LLVM/GCC backend
  ///   instead of the default mcode interpreter.
  /// - Cocotb: `{ "sim": "verilator" }` overrides the
  ///   underlying simulator the Makefile flow targets.
  ///
  /// Unknown keys are ignored by drivers that don't recognize them, so
  /// adding a new option is forward-compatible.
  final Map<String, String> options;

  /// Returns a copy with the given fields replaced.
  SimulatorBinaryConfig copyWith({
    String? simulatorId,
    SimulatorBinarySource? source,
    String? customPath,
    Map<String, String>? extraEnv,
    Map<String, String>? options,
  }) {
    return SimulatorBinaryConfig(
      simulatorId: simulatorId ?? this.simulatorId,
      source: source ?? this.source,
      customPath: customPath ?? this.customPath,
      extraEnv: extraEnv ?? this.extraEnv,
      options: options ?? this.options,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! SimulatorBinaryConfig) return false;
    if (other.simulatorId != simulatorId) return false;
    if (other.source != source) return false;
    if (other.customPath != customPath) return false;
    if (other.extraEnv.length != extraEnv.length) return false;
    for (final entry in extraEnv.entries) {
      if (other.extraEnv[entry.key] != entry.value) return false;
    }
    if (other.options.length != options.length) return false;
    for (final entry in options.entries) {
      if (other.options[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    simulatorId,
    source,
    customPath,
    Object.hashAllUnordered(
      extraEnv.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    Object.hashAllUnordered(
      options.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );
}
