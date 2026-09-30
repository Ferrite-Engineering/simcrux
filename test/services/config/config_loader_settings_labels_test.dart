// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/config_loader_error.dart';
import 'package:simcrux/services/config/config_loader.dart';

/// The project-tooling diagnostics send the user to a Settings control by
/// name. The loader cannot read the app's localizations (it is in the
/// Flutter-free CLI closure), so it spells the English labels as constants,
/// and this test holds each constant to the string the Settings screen
/// actually renders.
///
/// The diagnostics once said "Settings → Simulators → Allow project-defined
/// tooling" while the switch read "Let project files choose simulator
/// binaries and environment": a user following the message looked for a
/// control that did not exist.
void main() {
  final arb =
      jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
          as Map<String, Object?>;

  test('the tooling switch label is the Settings screen string', () {
    expect(
      kAllowProjectToolingControlLabel,
      arb['settingsAllowProjectDefinedToolingLabel'],
    );
  });

  test('the binary path field label is the Settings screen string', () {
    expect(
      kSimulatorBinaryPathControlLabel,
      arb['settingsSimulatorBinaryLabel'],
    );
  });

  test('the route names the Settings title and its Simulators section', () {
    expect(
      kSettingsSimulatorsRoute,
      '${arb['settingsTitle']} → ${arb['settingsSimulatorsSection']}',
    );
  });

  test('the remedy sentence carries the route, the label and the flag', () {
    expect(kProjectToolingRemedy, contains(kSettingsSimulatorsRoute));
    expect(kProjectToolingRemedy, contains(kAllowProjectToolingControlLabel));
    expect(kProjectToolingRemedy, contains('--allow-project-tooling'));
  });

  test('every gate diagnostic uses the real label', () {
    // One of each: a dropped simulator path, a dropped RISC-V executable
    // path, and a refused command.
    final loader = ConfigLoader();
    final warnings = loader.parse('''
version: "1"
defaults:
  simulator: icarus
  riscv:
    formal: { sby_binary: /tmp/x }
simulators:
  icarus: { source: custom, path: /tmp/x }
suites:
  s:
    tests:
      - name: t
        top: tb
''', '/p.yaml').loadWarnings;
    expect(warnings, hasLength(2));
    Object? refused;
    try {
      loader.parse('''
version: "1"
defaults:
  simulator: riscv_arch
  riscv:
    target: { command: [/tmp/x] }
suites:
  s:
    tests:
      - name: t
        top: tb
''', '/p.yaml');
    } on ConfigLoaderException catch (e) {
      refused = e.errors.first.message;
    }
    for (final message in <Object?>[
      ...warnings.map((w) => w.message),
      refused,
    ]) {
      expect(message, contains('"$kAllowProjectToolingControlLabel"'));
      expect(message, isNot(contains('Allow project-defined tooling')));
    }
  });
}
