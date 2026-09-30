// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/waveform_capture_policy.dart';
import 'package:simcrux/domain/enums/waveform_format.dart';
import 'package:simcrux/domain/models/test_spec.dart';

/// Encodes a [TestSpec] as the `spec` object of a driver-plugin `compile` or
/// `run` request.
///
/// This is the whole of what a plugin learns about the test it is asked to
/// build and run, so it carries everything a simulator command line needs.
/// The field names and value spellings are part of the plugin ABI
/// (`include/simcrux_driver_plugin_abi.md`, "The `spec` object"): enum values
/// use the same words as `simcrux.yaml` (`on_failure`, `system_verilog`), and
/// the host's pass/fail detector, resource locks and sweep templates stay on
/// the host side because the plugin has no use for them.
///
/// Adding a field is an additive (minor) ABI change; renaming or removing one
/// is a major one.
Map<String, Object?> encodePluginTestSpec(TestSpec spec) {
  return <String, Object?>{
    'id': spec.id,
    'name': spec.name,
    'suite': spec.suiteName,
    'simulatorId': spec.simulatorId,
    'top': spec.top,
    'sources': List<String>.of(spec.sources),
    'sourceLanguages': <String, String>{
      for (final entry in spec.sourceLanguages.entries)
        entry.key: _languageWireId(entry.value),
    },
    'includeDirs': List<String>.of(spec.includeDirs),
    'defines': Map<String, String>.of(spec.defines),
    'parameters': Map<String, String>.of(spec.parameters),
    'seed': spec.seed,
    'timeoutMs': spec.timeout.inMilliseconds,
    'waveform': <String, Object?>{
      'capture': _captureWireId(spec.waveform.capture),
      'format': _formatWireId(spec.waveform.format),
    },
  };
}

String _languageWireId(HdlLanguage language) => switch (language) {
  HdlLanguage.verilog => 'verilog',
  HdlLanguage.systemVerilog => 'system_verilog',
  HdlLanguage.vhdl => 'vhdl',
  HdlLanguage.python => 'python',
  HdlLanguage.mixed => 'mixed',
};

String _captureWireId(WaveformCapturePolicy capture) => switch (capture) {
  WaveformCapturePolicy.always => 'always',
  WaveformCapturePolicy.onFailure => 'on_failure',
  WaveformCapturePolicy.onDemand => 'on_demand',
  WaveformCapturePolicy.never => 'never',
};

String _formatWireId(WaveformFormat format) => switch (format) {
  WaveformFormat.vcd => 'vcd',
  WaveformFormat.fst => 'fst',
  WaveformFormat.ghw => 'ghw',
};
