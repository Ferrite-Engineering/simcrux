// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/domain/models/config_loader_error.dart';
import 'package:simcrux/domain/models/output_config.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/domain/models/riscv_config.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/waveform_policy.dart';

/// The root post-loader configuration for one `simcrux.yaml`
/// project.
///
/// Holds the suites (flattened — see `TestSpec`), the per-simulator
/// binary configuration, and project-level defaults (already pushed
/// down into each `TestSpec` by the loader; retained here for the
/// dashboard's "what was the default?" display).
@immutable
class RegressionConfig {
  /// Creates a [RegressionConfig].
  RegressionConfig({
    required this.projectFilePath,
    required this.schemaVersion,
    required List<Suite> suites,
    required Map<String, SimulatorBinaryConfig> simulatorBinaries,
    this.defaultSimulatorId,
    this.defaultPassFail,
    this.defaultWaveform,
    this.defaultRiscv,
    this.output = const OutputConfig(),
    List<ConfigLoaderError>? loadWarnings,
  }) : suites = List<Suite>.unmodifiable(suites),
       simulatorBinaries = Map<String, SimulatorBinaryConfig>.unmodifiable(
         simulatorBinaries,
       ),
       loadWarnings = List<ConfigLoaderError>.unmodifiable(
         loadWarnings ?? const <ConfigLoaderError>[],
       );

  /// Absolute path to the `simcrux.yaml` this config was loaded from.
  /// Used as the recent-projects entry and as the root for relative
  /// source-glob resolution.
  final String projectFilePath;

  /// The `version:` field from the YAML. Stored as a string so a
  /// future migration from `"1"` to `"1.1"` is non-breaking.
  final String schemaVersion;

  /// The project's suites, in declaration order.
  final List<Suite> suites;

  /// How to locate each simulator's binary. Keyed by simulator id
  /// (`icarus`, `verilator`, …). The default is one entry per
  /// known simulator pointing at `SimulatorBinarySource.bundled`.
  final Map<String, SimulatorBinaryConfig> simulatorBinaries;

  /// Project-level default simulator id (e.g. `icarus`). Pushed into
  /// each `TestSpec.simulatorId` at load time; retained here for the
  /// dashboard.
  final String? defaultSimulatorId;

  /// Project-level default pass/fail config. Pushed into each
  /// `TestSpec.passFail` at load time; retained here for the
  /// dashboard.
  final PassFailConfig? defaultPassFail;

  /// Project-level default waveform policy. Pushed into each
  /// `TestSpec.waveform` at load time; retained here for the
  /// dashboard.
  final WaveformPolicy? defaultWaveform;

  /// Project-level `defaults.riscv` block, already flattened over anything
  /// an including file supplied and already pushed down into each
  /// `TestSpec.riscv`.
  ///
  /// Retained here for the same reason the other three defaults are — the
  /// dashboard's "what was the default?" display — and because
  /// `_loadInternal` threads it into every `includes:` child as the first
  /// of the four inheritance levels.
  final RiscvConfig? defaultRiscv;

  /// Project-level `output:` block. Defaults to an unset
  /// [OutputConfig] (no streaming). The CI runner promotes the
  /// effective value to `streaming: true` when `--ci` is set.
  final OutputConfig output;

  /// Non-fatal advisory entries produced by the loader during the
  /// most recent load — typically tier-gate notices ("parameterization
  /// requires Pro — sweep block ignored"). The dashboard shows them in a
  /// banner above the results table; `--ci` prints them to stderr with a
  /// `warning:` prefix.
  ///
  /// Empty for the common case where the project loaded cleanly.
  /// `ConfigLoaderException` is reserved for hard errors that prevent
  /// loading; warnings always pass through to the caller.
  final List<ConfigLoaderError> loadWarnings;

  /// Returns a copy with the given fields replaced.
  RegressionConfig copyWith({
    String? projectFilePath,
    String? schemaVersion,
    List<Suite>? suites,
    Map<String, SimulatorBinaryConfig>? simulatorBinaries,
    String? defaultSimulatorId,
    PassFailConfig? defaultPassFail,
    WaveformPolicy? defaultWaveform,
    RiscvConfig? defaultRiscv,
    OutputConfig? output,
    List<ConfigLoaderError>? loadWarnings,
  }) {
    return RegressionConfig(
      projectFilePath: projectFilePath ?? this.projectFilePath,
      schemaVersion: schemaVersion ?? this.schemaVersion,
      suites: suites ?? this.suites,
      simulatorBinaries: simulatorBinaries ?? this.simulatorBinaries,
      defaultSimulatorId: defaultSimulatorId ?? this.defaultSimulatorId,
      defaultPassFail: defaultPassFail ?? this.defaultPassFail,
      defaultWaveform: defaultWaveform ?? this.defaultWaveform,
      defaultRiscv: defaultRiscv ?? this.defaultRiscv,
      output: output ?? this.output,
      loadWarnings: loadWarnings ?? this.loadWarnings,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! RegressionConfig) return false;
    if (other.projectFilePath != projectFilePath) return false;
    if (other.schemaVersion != schemaVersion) return false;
    if (other.defaultSimulatorId != defaultSimulatorId) return false;
    if (other.defaultPassFail != defaultPassFail) return false;
    if (other.defaultWaveform != defaultWaveform) return false;
    if (other.defaultRiscv != defaultRiscv) return false;
    if (other.output != output) return false;
    if (other.suites.length != suites.length) return false;
    for (var i = 0; i < suites.length; i++) {
      if (other.suites[i] != suites[i]) return false;
    }
    if (other.simulatorBinaries.length != simulatorBinaries.length) {
      return false;
    }
    for (final entry in simulatorBinaries.entries) {
      if (other.simulatorBinaries[entry.key] != entry.value) return false;
    }
    if (other.loadWarnings.length != loadWarnings.length) return false;
    for (var i = 0; i < loadWarnings.length; i++) {
      if (other.loadWarnings[i] != loadWarnings[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    projectFilePath,
    schemaVersion,
    Object.hashAll(suites),
    Object.hashAllUnordered(
      simulatorBinaries.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    defaultSimulatorId,
    defaultPassFail,
    defaultWaveform,
    defaultRiscv,
    output,
    Object.hashAll(loadWarnings),
  );
}
