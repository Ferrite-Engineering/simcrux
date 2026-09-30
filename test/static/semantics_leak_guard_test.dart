// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Static guard for the mandatory macOS semantics-leak suppressor.
//
// `integration_test/helpers/app_driver.dart` states the rule outright:
// "`suppressPlatformSemanticsLeak()` MUST be called in every macOS SimCrux
// integration test's `main()` right after
// `IntegrationTestWidgetsFlutterBinding.ensureInitialized()`."
//
// It was documented and not enforced, so files drifted off it across the suite. The
// macOS embedder raises "semantics enabled" mid-test when an accessibility
// client attaches; the resulting SemanticsHandle is never disposed and
// `_verifySemanticsHandlesWereDisposed` fails the test at teardown. Whether
// that happens is a property of the MACHINE, not the test — which is why the
// suppressor is applied blanket rather than per-symptom, and why the drift
// went unnoticed: a file without it fails only on a host where a client
// happens to attach, and passes everywhere else.
//
// Scope: every `integration_test/**/*_test.dart` that installs the
// integration binding. Files that do not install it never launch the real
// app, so no embedder signal can reach them — see the exemption below.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Files that legitimately do not install
/// [IntegrationTestWidgetsFlutterBinding]. These are widget tests that live
/// under `integration_test/` for their fixtures' sake but drive
/// `pumpWidget` against a `ProviderContainer` rather than booting the app,
/// so the platform semantics channel is never involved.
///
/// Membership is derived, not declared: the check below skips any file with
/// no `ensureInitialized()` call. This list exists to make the exempt set
/// visible and to fail loudly if one of them starts booting the real app
/// without adopting the guard.
const Set<String> kKnownNonBindingTests = <String>{};

void main() {
  test('every integration test that boots the app suppresses the '
      'macOS semantics leak', () {
    const bindingCall =
        'IntegrationTestWidgetsFlutterBinding'
        '.ensureInitialized()';
    final root = Directory('integration_test');
    expect(
      root.existsSync(),
      isTrue,
      reason: 'integration_test/ must exist for this guard to mean anything',
    );

    final offenders = <String>[];
    final exemptSeen = <String>{};

    for (final entity in root.listSync(recursive: true)) {
      if (entity is! File) continue;
      final path = entity.path.replaceAll(r'\', '/');
      if (!path.endsWith('_test.dart')) continue;
      // `web/` runs on chrome via its own driver, which has its own copy of
      // the suppressor and never sees the macOS embedder.
      if (path.contains('/web/')) continue;

      final source = entity.readAsStringSync();
      if (!source.contains(bindingCall)) {
        exemptSeen.add(path);
        continue;
      }
      // A test that skips on a desktop host never meets the macOS embedder,
      // so the suppressor would be noise there. `skipOnMobileDevice` is the
      // opposite case — it runs on desktop and DOES need the guard.
      if (source.contains('skip: skipOnDesktopHost')) continue;
      if (!source.contains('suppressPlatformSemanticsLeak()') &&
          !source.contains('disablePlatformSemantics()')) {
        offenders.add(path);
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These integration tests boot the real app but never call '
          'suppressPlatformSemanticsLeak(). They pass until they run on a '
          'host with an accessibility client attached, then fail at teardown '
          'on an undisposed SemanticsHandle. Add the call to main() directly '
          'after $bindingCall:\n${offenders.join('\n')}',
    );

    // The exempt set is expected to stay tiny and known. A new file landing
    // here means either a widget test was filed under integration_test/ (fine
    // — add it to the constant) or an integration test forgot its binding
    // (not fine — it will not run as one).
    expect(
      exemptSeen.difference(kKnownNonBindingTests),
      isEmpty,
      reason:
          'These files under integration_test/ install no integration '
          'binding. If a file is a widget test, add it to '
          'kKnownNonBindingTests; if it meant to be an integration test, it '
          'is missing $bindingCall:\n'
          '${exemptSeen.difference(kKnownNonBindingTests).join('\n')}',
    );
  });
}
