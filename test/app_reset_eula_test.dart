// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// `--reset-eula` was documented beside the EULA storage adapter and never
// parsed, so the agreement — deliberately once per installation — could only
// be seen a second time by editing preferences by hand. These drive the real
// `bootstrap` with the flag and read the same `SharedPreferences` key the
// acceptance store persists to, so they fail if the wiring is removed, moved
// behind the argument parser, or pointed at a different store.
//
// `--help` makes each invocation headless: bootstrap returns right after the
// parser, without building the app, so the reset is observable on its own.

import 'dart:async';

import 'package:crux_eula/crux_eula.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/app.dart';

Future<bool> _bootstrapQuietly(List<String> args) => runZoned(
  () => bootstrap(args: args),
  zoneSpecification: ZoneSpecification(
    print: (self, parent, zone, line) {},
  ),
);

Future<String?> _acceptedVersion() async =>
    (await SharedPreferences.getInstance()).getString(
      kCruxEulaAcceptedVersionKey,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      kCruxEulaAcceptedVersionKey: kCruxEulaVersion,
    });
  });

  test('--reset-eula forgets the accepted agreement version', () async {
    expect(await _acceptedVersion(), kCruxEulaVersion);

    expect(await _bootstrapQuietly(<String>['--reset-eula', '--help']), isTrue);

    expect(
      await _acceptedVersion(),
      isNull,
      reason:
          'the acceptance must be gone before the gate first reads it, so '
          'the agreement is presented on this same launch',
    );
  });

  test('without the flag the acceptance is kept', () async {
    expect(await _bootstrapQuietly(<String>['--help']), isTrue);

    expect(await _acceptedVersion(), kCruxEulaVersion);
  });
}
