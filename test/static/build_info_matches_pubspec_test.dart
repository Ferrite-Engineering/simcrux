// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/app_info/build_info.dart';

/// Static guard: [SimCruxBuildInfo.productVersion] equals the `version:` in
/// `pubspec.yaml`, minus the build number.
///
/// **This guard exists because the constant it checks was already wrong.** The
/// CXP handshake advertised `0.1.0` to every peer of every 0.8.0 build, for
/// several releases, under a doc comment promising it was "kept in sync with
/// `pubspec.yaml` by convention". Nothing failed, so nobody looked. That is the
/// entire argument for this file: a hand-maintained constant is safe exactly as
/// long as something goes red when it rots, and "by convention" is not that
/// something.
///
/// It matters more now than it did then. The constant is what `crux_sqlite`
/// stamps into `schema_meta.app_version` and every `schema_migrations` row —
/// so a stale value does not merely misreport a version, it writes a false
/// provenance record into a user's database, permanently, on a row nothing will
/// ever revisit. A ledger is only worth reading if the thing writing it is
/// telling the truth.
///
/// MUTATION: bump `version:` in `pubspec.yaml` without touching
/// `build_info.dart` (or the reverse) and this guard fails, naming both.
void main() {
  test('SimCruxBuildInfo.productVersion matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml');
    expect(
      pubspec.existsSync(),
      isTrue,
      reason: 'run from the package root (cwd = simcrux/)',
    );

    final line = pubspec.readAsLinesSync().firstWhere(
      (l) => l.startsWith('version:'),
      orElse: () => '',
    );
    expect(line, isNotEmpty, reason: 'pubspec.yaml has no version: line');

    // `1.0.0+9` -> `1.0.0`. The build number is deliberately not part of the
    // constant: it differs between the open-core and Pro pubspecs of the same
    // release, and schema_meta wants the release, not the build counter.
    final semver = line.substring('version:'.length).trim().split('+').first;

    expect(
      SimCruxBuildInfo.productVersion,
      semver,
      reason:
          'SimCruxBuildInfo.productVersion is "${SimCruxBuildInfo.productVersion}" '
          'but pubspec.yaml says "$semver". This constant is what the CXP '
          'handshake advertises AND what crux_sqlite writes into '
          'schema_meta.app_version and every schema_migrations row, so a stale '
          "value writes a false provenance record into users' databases. "
          'Update lib/core/app_info/build_info.dart to match pubspec.yaml.',
    );
  });

  test('the product identifier is the suite-stable lowercase one', () {
    expect(
      SimCruxBuildInfo.productName,
      'simcrux',
      reason:
          'schema_meta.product and the CXP wire both carry this. It is a '
          'machine identifier shared across the suite (wavecrux, netcrux, '
          'lintcrux, simcrux), not a display name',
    );
  });
}
