// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/waveform_capture_policy.dart';
import 'package:simcrux/domain/enums/waveform_format.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/domain/models/waveform_policy.dart';
import 'package:simcrux/services/driver_plugin/plugin_test_spec_codec.dart';

void main() {
  group('encodePluginTestSpec', () {
    test('carries every field the ABI spec table names', () {
      final encoded = encodePluginTestSpec(
        TestSpec(
          id: 'cpu/alu+WIDTH=8+seed=7',
          name: 'alu',
          suiteName: 'cpu',
          simulatorId: 'questa',
          top: 'tb_alu',
          sources: const ['rtl/alu.sv', 'rtl/pkg.vhd'],
          sourceLanguages: const {'rtl/pkg.vhd': HdlLanguage.vhdl},
          includeDirs: const ['rtl/include'],
          defines: const {'SIM': '1'},
          parameters: const {'WIDTH': '8'},
          seed: 7,
          timeout: const Duration(minutes: 2),
          // No waveform: the default policy, on_failure / fst.
        ),
      );
      expect(encoded, <String, Object?>{
        'id': 'cpu/alu+WIDTH=8+seed=7',
        'name': 'alu',
        'suite': 'cpu',
        'simulatorId': 'questa',
        'top': 'tb_alu',
        'sources': ['rtl/alu.sv', 'rtl/pkg.vhd'],
        'sourceLanguages': {'rtl/pkg.vhd': 'vhdl'},
        'includeDirs': ['rtl/include'],
        'defines': {'SIM': '1'},
        'parameters': {'WIDTH': '8'},
        'seed': 7,
        'timeoutMs': 120000,
        'waveform': {'capture': 'on_failure', 'format': 'fst'},
      });
    });

    test('uses the simcrux.yaml spellings for enum values', () {
      final encoded = encodePluginTestSpec(
        TestSpec(
          id: 's/t',
          name: 't',
          suiteName: 's',
          simulatorId: 'x',
          top: 'tb',
          sourceLanguages: const {'a.sv': HdlLanguage.systemVerilog},
          waveform: const WaveformPolicy(
            capture: WaveformCapturePolicy.onDemand,
            format: WaveformFormat.ghw,
          ),
        ),
      );
      expect(encoded['sourceLanguages'], {'a.sv': 'system_verilog'});
      expect(encoded['waveform'], {'capture': 'on_demand', 'format': 'ghw'});
      expect(encoded['seed'], isNull);
    });

    test('is plain JSON — it survives a jsonEncode round trip', () {
      final spec = TestSpec(
        id: 's/t',
        name: 't',
        suiteName: 's',
        simulatorId: 'x',
        top: 'tb',
        sources: const ['a.v'],
      );
      final encoded = encodePluginTestSpec(spec);
      expect(jsonDecode(jsonEncode(encoded)), encoded);
      expect(jsonEncode(encoded), isNot(contains('Instance of')));
    });
  });
}
