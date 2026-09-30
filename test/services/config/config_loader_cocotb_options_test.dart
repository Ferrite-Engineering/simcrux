// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/config_loader_error.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/services/config/config_loader.dart';

// cocotb's `max_failures` used to be checked only by the driver, after the
// test was dispatched: the run waited out its timeout in the app, and the
// standalone binary died with exit 255. It is now a load error.

RegressionConfig _parse(String yaml) =>
    ConfigLoader().parse(yaml, '/p/simcrux.yaml');

ConfigLoaderException _parseError(String yaml) {
  try {
    _parse(yaml);
  } on ConfigLoaderException catch (e) {
    return e;
  }
  fail('expected ConfigLoaderException');
}

void main() {
  group('cocotb max_failures is validated at load', () {
    test('a non-numeric project-wide value is rejected with its line', () {
      final e = _parseError('''
version: "1"
simulators:
  cocotb:
    options:
      max_failures: "abc"
suites:
  s:
    simulator: cocotb
    tests:
      - name: t
        top: dff
''');
      final error = e.errors.single;
      expect(error.message, contains('simulators.cocotb.options.max_failures'));
      expect(error.message, contains('positive integer'));
      expect(error.line, 5);
    });

    test('zero is rejected', () {
      final e = _parseError('''
version: "1"
simulators:
  cocotb:
    options:
      max_failures: "0"
suites:
  s:
    simulator: cocotb
    tests:
      - name: t
        top: dff
''');
      expect(e.errors.single.message, contains('max_failures'));
    });

    test('a per-test parameter is rejected', () {
      final e = _parseError('''
version: "1"
suites:
  s:
    simulator: cocotb
    tests:
      - name: t
        top: dff
        parameters:
          max_failures: "-3"
''');
      expect(e.errors.single.message, contains('parameters.max_failures'));
    });

    test('a positive integer loads', () {
      final config = _parse('''
version: "1"
simulators:
  cocotb:
    options:
      max_failures: "5"
suites:
  s:
    simulator: cocotb
    tests:
      - name: t
        top: dff
''');
      expect(
        config.simulatorBinaries['cocotb']!.options['max_failures'],
        '5',
      );
    });

    test("another simulator's option of the same name is not checked", () {
      final config = _parse('''
version: "1"
simulators:
  verilator:
    options:
      max_failures: "not cocotb"
suites:
  s:
    simulator: verilator
    tests:
      - name: t
        top: tb
''');
      expect(config.suites.single.tests.single.simulatorId, 'verilator');
    });
  });
}
