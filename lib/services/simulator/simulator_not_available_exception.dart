// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/domain/models/simulator_binary_config.dart';

/// Thrown when a simulator binary cannot be located on the host.
///
/// The driver wraps this exception with a clear message that mentions
/// the binary it tried to run and the resolution path
/// ([SimulatorBinarySource]) so the UI can surface a remediation hint
/// without parsing the platform's error text.
///
/// Shared by every process-backed simulator driver (Icarus, GHDL,
/// Verilator, Cocotb) and caught by the scheduler. It lived in
/// `icarus_driver.dart` historically; the other drivers imported it
/// from there via `show`, which coupled them to a sibling
/// implementation. It now has its own home so every driver — and the
/// scheduler — depends on the exception, not on Icarus.
class SimulatorNotAvailableException implements Exception {
  /// Creates a [SimulatorNotAvailableException].
  SimulatorNotAvailableException({
    required this.simulatorId,
    required this.binary,
    required this.source,
    this.cause,
    this.toolName,
    this.remediationOverride,
  });

  /// The `SimulatorDriver.id` (e.g. `icarus`).
  final String simulatorId;

  /// The binary name or path the driver tried to invoke.
  final String binary;

  /// How the driver was resolving the binary
  /// ([SimulatorBinarySource.system] / `bundled` / `custom`).
  final SimulatorBinarySource source;

  /// Underlying OS error, when one is available.
  final Object? cause;

  /// The tool's own name for messages (`SymbiYosys`), when it is not the
  /// simulator id. A driver id such as `riscv_formal` is not something a
  /// user installs, so "Install riscv_formal" sent people looking for a
  /// package that does not exist.
  final String? toolName;

  /// The driver's own guidance, used in place of [remediation]'s
  /// per-source text. Set by drivers whose engine is not configured
  /// through `Settings → Engines` alone (SymbiYosys under riscv-formal),
  /// so a headless run is not pointed at a setting it does not have.
  final String? remediationOverride;

  /// What the user should do about it, phrased per resolution source.
  ///
  /// The old message ended at "via $source resolution", which printed
  /// `SimulatorBinarySource.bundled` — enum-name and all — at a user who
  /// had simply not installed Icarus. It read as *the copy SimCrux
  /// shipped is broken*, which sent people looking inside the app bundle
  /// for a binary that was never there. Each source now names the actual
  /// remedy.
  String get remediation {
    final override = remediationOverride;
    if (override != null && override.isNotEmpty) return override;
    final simulatorId = toolName ?? this.simulatorId;
    switch (source) {
      case SimulatorBinarySource.system:
        return 'Install $simulatorId and make sure `$binary` is on your '
            'PATH, or set an explicit path in Settings → Engines. '
            'On macOS, an app launched from Finder does not inherit your '
            "shell's PATH — a Homebrew install can be invisible even "
            'though `which $binary` works in a terminal.';
      case SimulatorBinarySource.bundled:
        return 'This build has no bundled $simulatorId. Install it and put '
            '`$binary` on your PATH, or set an explicit path in '
            'Settings → Engines.';
      case SimulatorBinarySource.custom:
        return 'The configured path for $simulatorId does not point at a '
            'runnable `$binary`. Check the Settings → Engines override '
            'or the `simulators:` block in your simcrux.yaml.';
    }
  }

  @override
  String toString() {
    final base = toolName != null
        ? '$toolName: could not run `$binary`. $remediation'
        : '$simulatorId driver: could not run `$binary`. $remediation';
    if (cause == null) return base;
    return '$base ($cause)';
  }
}
