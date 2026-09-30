// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';

void main() {
  group('SimulatorBinaryConfig', () {
    test('default source is system and extraEnv is empty', () {
      const config = SimulatorBinaryConfig(simulatorId: 'icarus');
      expect(
        config.source,
        SimulatorBinarySource.system,
        reason:
            'nothing is bundled — assets/sim_binaries/ does not exist. '
            'The default was `bundled`, which made a simulator the user had '
            'simply not installed report itself as a broken bundled copy.',
      );
      expect(config.customPath, isNull);
      expect(config.extraEnv, isEmpty);
    });

    test('copyWith replaces individual fields', () {
      const original = SimulatorBinaryConfig(simulatorId: 'icarus');
      final updated = original.copyWith(
        source: SimulatorBinarySource.custom,
        customPath: '/usr/local/bin/iverilog',
      );
      expect(updated.source, SimulatorBinarySource.custom);
      expect(updated.customPath, '/usr/local/bin/iverilog');
      expect(updated.simulatorId, 'icarus');
    });

    test('equality compares simulatorId, source, customPath, extraEnv', () {
      const a = SimulatorBinaryConfig(simulatorId: 'icarus');
      const b = SimulatorBinaryConfig(simulatorId: 'icarus');
      const c = SimulatorBinaryConfig(
        simulatorId: 'icarus',
        source: SimulatorBinarySource.bundled,
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });

    test('equality treats extraEnv as a set of key/value pairs', () {
      final a = const SimulatorBinaryConfig(simulatorId: 'questa').copyWith(
        extraEnv: const {'LM_LICENSE_FILE': '/opt/lic'},
      );
      final b = const SimulatorBinaryConfig(simulatorId: 'questa').copyWith(
        extraEnv: const {'LM_LICENSE_FILE': '/opt/lic'},
      );
      final c = const SimulatorBinaryConfig(simulatorId: 'questa').copyWith(
        extraEnv: const {'LM_LICENSE_FILE': '/different'},
      );
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });

    test('options defaults to empty map and round-trips through copyWith', () {
      const a = SimulatorBinaryConfig(simulatorId: 'ghdl');
      expect(a.options, isEmpty);
      final b = a.copyWith(options: const {'backend': 'llvm'});
      expect(b.options, {'backend': 'llvm'});
      // Original is unchanged.
      expect(a.options, isEmpty);
    });

    test('equality treats options as a set of key/value pairs', () {
      final a = const SimulatorBinaryConfig(simulatorId: 'ghdl').copyWith(
        options: const {'backend': 'llvm'},
      );
      final b = const SimulatorBinaryConfig(simulatorId: 'ghdl').copyWith(
        options: const {'backend': 'llvm'},
      );
      final c = const SimulatorBinaryConfig(simulatorId: 'ghdl').copyWith(
        options: const {'backend': 'mcode'},
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });
  });
}
