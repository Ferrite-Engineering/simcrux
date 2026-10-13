// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/config_loader_error.dart';
import 'package:simcrux/domain/models/simulator_policy.dart';
import 'package:simcrux/services/config/config_loader.dart';

/// The organization's simulator policy as the loader applies it: the
/// fallback simulator is the last level of the lookup, and the allow-list
/// refuses any test whose simulator it does not name.
void main() {
  const path = '/proj/simcrux.yaml';

  String project({String? defaultsSimulator, String? suiteSimulator}) =>
      '''
version: "1"
${defaultsSimulator == null ? '' : 'defaults:\n  simulator: $defaultsSimulator\n'}
suites:
  unit:
${suiteSimulator == null ? '' : '    simulator: $suiteSimulator\n'}    sources:
      - tb/alu_tb.v
    tests:
      - name: alu_basic
        top: alu_tb
      - name: alu_vhdl
        top: alu_tb
        simulator: ghdl
''';

  List<String> errorsOf(void Function() load) {
    try {
      load();
    } on ConfigLoaderException catch (e) {
      return e.errors.map((err) => err.message).toList();
    }
    fail('expected a ConfigLoaderException');
  }

  group('fallbackSimulatorId', () {
    test('without a policy, a test with no simulator is a load error', () {
      final errors = errorsOf(() => ConfigLoader().parse(project(), path));
      expect(errors.single, contains('`unit/alu_basic` has no simulator'));
    });

    test('fills in when defaults, suite and test name none', () {
      final config = ConfigLoader(
        simulatorPolicy: const SimulatorPolicy(fallbackSimulatorId: 'icarus'),
      ).parse(project(), path);
      final tests = config.suites.single.tests;
      expect(tests.first.simulatorId, 'icarus');
      // The test that names one keeps it.
      expect(tests.last.simulatorId, 'ghdl');
      // The fallback is not written back as the file's own default.
      expect(config.defaultSimulatorId, isNull);
    });

    test('defaults.simulator wins over the fallback', () {
      final config = ConfigLoader(
        simulatorPolicy: const SimulatorPolicy(fallbackSimulatorId: 'icarus'),
      ).parse(project(defaultsSimulator: 'verilator'), path);
      expect(config.suites.single.tests.first.simulatorId, 'verilator');
    });

    test("the suite's simulator wins over the fallback", () {
      final config = ConfigLoader(
        simulatorPolicy: const SimulatorPolicy(fallbackSimulatorId: 'icarus'),
      ).parse(project(suiteSimulator: 'verilator'), path);
      expect(config.suites.single.tests.first.simulatorId, 'verilator');
    });

    test(
      "an including file's defaults.simulator wins over the fallback",
      () async {
        final files = <String, String>{
          '/proj/simcrux.yaml': '''
version: "1"
defaults:
  simulator: verilator
includes:
  - sub.yaml
suites:
  top:
    sources: [tb/top_tb.v]
    tests:
      - name: smoke
        top: top_tb
''',
          '/proj/sub.yaml': '''
version: "1"
suites:
  sub:
    sources: [tb/sub_tb.v]
    tests:
      - name: inner
        top: sub_tb
''',
        };
        final config = await ConfigLoader(
          readFile: (p) async => files[p] ?? (throw StateError('no $p')),
          simulatorLanguages: const {},
          simulatorPolicy: const SimulatorPolicy(fallbackSimulatorId: 'icarus'),
        ).load('/proj/simcrux.yaml');
        final inner = config.suites
            .singleWhere((s) => s.name == 'sub')
            .tests
            .single;
        expect(inner.simulatorId, 'verilator');
      },
    );
  });

  group('allowedSimulatorIds', () {
    test('refuses a test whose simulator is not listed, naming it', () {
      final errors = errorsOf(
        () => ConfigLoader(
          simulatorPolicy: const SimulatorPolicy(
            allowedSimulatorIds: {'verilator', 'icarus'},
          ),
        ).parse(project(defaultsSimulator: 'icarus'), path),
      );
      expect(errors, [
        ConfigLoader.simulatorNotAllowedMessage(
          testId: 'unit/alu_vhdl',
          simulatorId: 'ghdl',
          allowed: const {'icarus', 'verilator'},
        ),
      ]);
      expect(errors.single, contains('simulatorBinaryPolicy'));
      // Sorted, so the message is stable whatever order the policy used.
      expect(errors.single, contains('Allowed simulators: icarus, verilator.'));
    });

    test('loads when every test uses a listed simulator', () {
      final config = ConfigLoader(
        simulatorPolicy: const SimulatorPolicy(
          allowedSimulatorIds: {'icarus', 'ghdl'},
        ),
      ).parse(project(defaultsSimulator: 'icarus'), path);
      expect(config.suites.single.tests, hasLength(2));
    });

    test('checks the fallback simulator too', () {
      final errors = errorsOf(
        () => ConfigLoader(
          simulatorPolicy: const SimulatorPolicy(
            fallbackSimulatorId: 'icarus',
            allowedSimulatorIds: {'ghdl'},
          ),
        ).parse(project(), path),
      );
      expect(
        errors.single,
        contains('`unit/alu_basic` uses simulator `icarus`'),
      );
    });

    test('an empty list refuses everything and says so', () {
      final errors = errorsOf(
        () => ConfigLoader(
          simulatorPolicy: const SimulatorPolicy(
            allowedSimulatorIds: <String>{},
          ),
        ).parse(project(defaultsSimulator: 'icarus'), path),
      );
      expect(errors, hasLength(2));
      expect(errors.first, contains('Allowed simulators: none.'));
    });

    test('the refusal is fatal, never a dropped test', () {
      // A dropped test would let a `--ci` run report green on fewer tests
      // than the project declares.
      expect(
        () => ConfigLoader(
          simulatorPolicy: const SimulatorPolicy(
            allowedSimulatorIds: {'icarus'},
          ),
        ).parse(project(defaultsSimulator: 'icarus'), path),
        throwsA(
          isA<ConfigLoaderException>().having(
            (e) => e.errors.every((err) => err.isFatal),
            'all fatal',
            isTrue,
          ),
        ),
      );
    });
  });
}
