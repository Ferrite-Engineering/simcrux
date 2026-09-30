// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// Capabilities a [SimulatorDriver]-backed plugin declares in its
/// manifest. The host uses this set to gate optional surface (e.g.
/// hide a "coverage" toggle when the active driver does not declare
/// [DriverCapability.coverage]) and to surface capability chips in the
/// Settings → Plugins panel.
///
/// Part of the driver plugin SDK. The vocabulary is intentionally
/// narrow at v1; future ABI revisions may add values without breaking
/// existing plugins (unknown capabilities are silently ignored by the
/// host).
enum DriverCapability {
  /// Driver implements `compile()` (i.e. produces an intermediate
  /// artifact distinct from the run step).
  compile,

  /// Driver implements `run()` (the typical case — every functional
  /// driver declares this).
  run,

  /// Driver collects coverage data during runs and surfaces a
  /// per-test coverage report.
  coverage,

  /// Driver can emit a waveform dump (VCD / FST / GHW / proprietary)
  /// when the host requests one via the test spec.
  waveformDump,

  /// Driver supports interactive debugging hooks (breakpoint set /
  /// step / inspect). Reserved for future driver implementations; v1
  /// plugin SDK does not exercise this capability beyond manifest
  /// declaration.
  interactiveDebug,

  /// Driver can sweep across a parameter axis natively (parameter
  /// values are passed in the run request). When unset, the host
  /// expands sweeps into N distinct run requests.
  parameterSweeps,

  /// Driver emits incremental progress events during long compile /
  /// run operations (the wire-protocol `runProgress` /
  /// `compileProgress` envelopes).
  liveProgress;

  /// Stable wire-protocol id used in JSON manifests + JSONL messages.
  /// Kept identical to the Dart enum name so JSON round-tripping is
  /// trivial.
  String get wireId => name;

  /// Decodes a wire-protocol id into a [DriverCapability]. Returns
  /// `null` for unknown ids — callers silently skip those entries to
  /// preserve forward compatibility with newer plugins.
  static DriverCapability? fromWireId(String wireId) {
    for (final value in DriverCapability.values) {
      if (value.wireId == wireId) {
        return value;
      }
    }
    return null;
  }
}
