// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/golden_compare_profile.dart';

// The wire names land in user `simcrux.yaml` files and in the settings
// store, so they are API. This file pins them.
void main() {
  test('wire names are stable — they land in user config files', () {
    expect(GoldenCompareProfile.generic.wireName, 'generic');
    expect(GoldenCompareProfile.riscvSignature.wireName, 'riscv_signature');
    expect(GoldenCompareProfile.wireNames, ['generic', 'riscv_signature']);
  });

  test('fromWireName round-trips every value and rejects the rest', () {
    for (final profile in GoldenCompareProfile.values) {
      expect(GoldenCompareProfile.fromWireName(profile.wireName), profile);
    }
    expect(GoldenCompareProfile.fromWireName('riscv'), isNull);
    expect(GoldenCompareProfile.fromWireName(''), isNull);
    expect(GoldenCompareProfile.fromWireName(null), isNull);
    expect(GoldenCompareProfile.fromWireName(42), isNull);
  });

  test('only riscv_signature carries conventional filenames', () {
    expect(GoldenCompareProfile.generic.defaultDutPath, isNull);
    expect(GoldenCompareProfile.generic.defaultReferencePath, isNull);
    expect(
      GoldenCompareProfile.riscvSignature.defaultDutPath,
      'signature.dut.sig',
    );
    expect(
      GoldenCompareProfile.riscvSignature.defaultReferencePath,
      'signature.ref.sig',
    );
  });

  test('a profile never points both defaults at the same file', () {
    // dut == reference would always compare equal — the loader rejects
    // it, and a profile must never hand that in by default.
    for (final profile in GoldenCompareProfile.values) {
      final dut = profile.defaultDutPath;
      if (dut == null) continue;
      expect(dut, isNot(profile.defaultReferencePath));
    }
  });
}
