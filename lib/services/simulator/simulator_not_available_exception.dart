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

  /// What the user should do about it, phrased per resolution source.
  ///
  /// The old message ended at "via $source resolution", which printed
  /// `SimulatorBinarySource.bundled` — enum-name and all — at a user who
  /// had simply not installed Icarus. It read as *the copy SimCrux
  /// shipped is broken*, which sent people looking inside the app bundle
  /// for a binary that was never there. Each source now names the actual
  /// remedy.
  String get remediation {
    switch (source) {
      case SimulatorBinarySource.system:
        return 'Install $simulatorId and make sure `$binary` is on your '
            'PATH, or set an explicit path in Settings → Simulators. '
            'On macOS, an app launched from Finder does not inherit your '
            "shell's PATH — a Homebrew install can be invisible even "
            'though `which $binary` works in a terminal.';
      case SimulatorBinarySource.bundled:
        return 'This build has no bundled $simulatorId. Install it and put '
            '`$binary` on your PATH, or set an explicit path in '
            'Settings → Simulators.';
      case SimulatorBinarySource.custom:
        return 'The configured path for $simulatorId does not point at a '
            'runnable `$binary`. Check the Settings → Simulators override '
            'or the `simulators:` block in your simcrux.yaml.';
    }
  }

  @override
  String toString() {
    final base = '$simulatorId driver: could not run `$binary`. $remediation';
    if (cause == null) return base;
    return '$base ($cause)';
  }
}
