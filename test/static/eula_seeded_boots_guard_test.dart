// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Static guard: every integration-test boot seeds EULA acceptance first.
//
// `CruxEulaGate` covers the whole app with a modal barrier until the
// agreement is accepted, so an integration test that boots without seeding
// acceptance has every tap miss, and because the integration suite runs
// weekly the failure surfaces up to a week late, behind whatever else broke
// that week. `crux_eula`'s `cruxAuditEulaSeededBoots` finds a `bootstrap(`
// with no `seedEulaAcceptance()` (or `kCruxEulaAcceptedVersionKey`) earlier
// in the same function or in a `setUp`. `bootSimcrux`, the helper every
// journey uses, seeds inside itself before it calls `bootstrap`, which is
// why it is not a boot call of its own here; a test that calls `bootstrap`
// directly is held to the rule.

import 'dart:io';

import 'package:crux_eula/crux_eula_guards.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('every integration-test boot seeds EULA acceptance first', () {
    final root = Directory('integration_test');
    expect(root.existsSync(), isTrue, reason: 'run from the repository root');
    final sources = <CruxEulaGuardSource>[
      for (final entity in root.listSync(recursive: true))
        if (entity is File && entity.path.endsWith('.dart'))
          CruxEulaGuardSource(
            path: p.relative(entity.path).replaceAll(r'\', '/'),
            source: entity.readAsStringSync(),
          ),
    ];
    // Non-vacuity: the helper that boots the app must be among the sources,
    // or the scan is looking at nothing.
    expect(
      sources.any((s) => s.source.contains('await bootstrap(')),
      isTrue,
      reason: 'no integration-test source calls bootstrap; is the walk right?',
    );

    final findings = cruxAuditEulaSeededBoots(
      sources: sources,
      // The scanner's defaults are this repository's names, and they are
      // named here so the test says what it checks for: `bootstrap` is the
      // boot.
      // ignore: avoid_redundant_argument_values
      bootCalls: const <String>{'bootstrap'},
      // And `seedEulaAcceptance` the seed.
      // ignore: avoid_redundant_argument_values
      seedCalls: const <String>{'seedEulaAcceptance'},
    );
    expect(findings, isEmpty, reason: findings.join('\n'));
  });
}
