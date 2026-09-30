// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/services/simulator/simulator_not_available_exception.dart';

SimulatorNotAvailableException _ex(SimulatorBinarySource source) =>
    SimulatorNotAvailableException(
      simulatorId: 'icarus',
      binary: 'iverilog',
      source: source,
    );

void main() {
  group('remediation names the actual remedy per source', () {
    test('system points at PATH and the Settings override', () {
      final message = _ex(SimulatorBinarySource.system).remediation;
      expect(message, contains('PATH'));
      expect(message, contains('Settings → Simulators'));
    });

    test('system warns about the macOS Finder PATH trap', () {
      // The single most common support question: `which iverilog` works in
      // a terminal, the app launched from Finder cannot see it.
      final message = _ex(SimulatorBinarySource.system).remediation;
      expect(message, contains('macOS'));
      expect(message, contains('Finder'));
    });

    test('bundled says this build has none rather than implying it is '
        'broken', () {
      final message = _ex(SimulatorBinarySource.bundled).remediation;
      expect(message, contains('no bundled'));
      expect(message, contains('PATH'));
    });

    test('custom points at the configured path', () {
      final message = _ex(SimulatorBinarySource.custom).remediation;
      expect(message, contains('configured path'));
      expect(message, contains('simcrux.yaml'));
    });
  });

  group('toString', () {
    test('names the binary and carries the remediation', () {
      final text = _ex(SimulatorBinarySource.system).toString();
      expect(text, contains('icarus'));
      expect(text, contains('`iverilog`'));
      expect(text, contains('PATH'));
    });

    test('never prints a raw enum name at the user', () {
      // The old message ended "via $source resolution", which rendered
      // `SimulatorBinarySource.bundled` verbatim.
      for (final source in SimulatorBinarySource.values) {
        expect(
          _ex(source).toString(),
          isNot(contains('SimulatorBinarySource.')),
          reason: '$source leaked its enum name into user-facing text',
        );
      }
    });

    test('appends the OS cause when there is one', () {
      final text = SimulatorNotAvailableException(
        simulatorId: 'icarus',
        binary: 'iverilog',
        source: SimulatorBinarySource.system,
        cause: 'No such file or directory',
      ).toString();
      expect(text, contains('No such file or directory'));
    });
  });
}
