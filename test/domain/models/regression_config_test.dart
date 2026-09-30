// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_spec.dart';

TestSpec _spec(String id) => TestSpec(
  id: id,
  name: id,
  suiteName: 'cpu_unit',
  simulatorId: 'icarus',
  top: 'tb',
);

RegressionConfig _config({String? defaultSim}) {
  return RegressionConfig(
    projectFilePath: '/repo/simcrux.yaml',
    schemaVersion: '1',
    suites: [
      Suite(name: 'cpu_unit', tests: [_spec('cpu_unit/alu_basic')]),
    ],
    simulatorBinaries: const {
      'icarus': SimulatorBinaryConfig(simulatorId: 'icarus'),
    },
    defaultSimulatorId: defaultSim,
  );
}

void main() {
  group('RegressionConfig', () {
    test('suites and simulatorBinaries are wrapped unmodifiable', () {
      final config = _config();
      expect(
        () => config.suites.add(Suite(name: 'x', tests: const [])),
        throwsUnsupportedError,
      );
      expect(
        () => config.simulatorBinaries['x'] = const SimulatorBinaryConfig(
          simulatorId: 'x',
        ),
        throwsUnsupportedError,
      );
    });

    test('copyWith replaces fields', () {
      final config = _config();
      final updated = config.copyWith(defaultSimulatorId: 'verilator');
      expect(updated.defaultSimulatorId, 'verilator');
      expect(updated.projectFilePath, config.projectFilePath);
    });

    test(
      'equality compares projectFilePath / schemaVersion / suites / etc.',
      () {
        final a = _config(defaultSim: 'icarus');
        final b = _config(defaultSim: 'icarus');
        final c = _config(defaultSim: 'verilator');
        expect(a, equals(b));
        expect(a.hashCode, b.hashCode);
        expect(a, isNot(equals(c)));
      },
    );
  });
}
