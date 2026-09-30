// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// EULA section 2.1 says the application presents the agreement on first launch
// and does not proceed until it is accepted. `crux_eula` implements that and
// tests itself thoroughly — but a shared widget that nothing mounts is a
// promise the suite is not keeping, and the package's own green suite cannot
// see it. Several Enterprise features have already been found built, tested
// and constructed nowhere; this is the cheap guard that stops the agreement
// becoming the next one.
//
// Three claims, all mechanically checkable against app.dart:
//
//  1. The gate is mounted at all.
//  2. It wraps OUTSIDE `TelemetryConsentGate`. Not a style preference — the
//     telemetry disclosure asks consent for a term the EULA defines (EULA 8),
//     so collecting it first has the user answering a question about a
//     contract they were never shown, and the EEA/UK/CH/KR opt-in default
//     stops being defensible.
//  3. The persistence seam is bound. Unbound, the package falls back to an
//     in-memory store, and the agreement is presented on every single launch.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String app;

  setUpAll(() {
    final file = File('lib/app.dart');
    expect(
      file.existsSync(),
      isTrue,
      reason: 'run this from the package root',
    );
    app = file.readAsStringSync();
  });

  test('the EULA gate is mounted', () {
    expect(
      app,
      contains('CruxEulaGate('),
      reason:
          'EULA 2.1 promises the agreement is presented on first launch, and '
          'that promise covers Open Core. Nothing mounts CruxEulaGate.',
    );
  });

  test('the EULA gate wraps outside the telemetry disclosure', () {
    final eula = app.indexOf('CruxEulaGate(');
    final telemetry = app.indexOf('TelemetryConsentGate(');

    expect(eula, isNonNegative);
    expect(telemetry, isNonNegative);
    expect(
      eula,
      lessThan(telemetry),
      reason:
          'TelemetryConsentGate is mounted outside CruxEulaGate. The telemetry '
          'disclosure asks for consent to a term the EULA defines (EULA 8), so '
          'it cannot be the first thing the user answers — and consent '
          'gathered before the agreement that defines what is collected is '
          'not informed consent, which is what the EEA/UK/CH/KR opt-in '
          'default rests on.',
    );
  });

  test('the acceptance store is bound to real persistence', () {
    expect(
      app,
      contains('simcruxEulaOverrides'),
      reason:
          'Without this the package falls back to InMemoryCruxEulaStorage and '
          'the agreement is presented on every launch.',
    );
  });
}
