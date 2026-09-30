// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/dashboard/providers/riscv_compatibility_opener.dart';

void main() {
  group('riscvCompatibilityOpenerProvider', () {
    test('open-core default is null (no opener registered)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(riscvCompatibilityOpenerProvider), isNull);
    });

    test('override surfaces a callable opener', () {
      var callCount = 0;
      final container = ProviderContainer(
        overrides: [
          riscvCompatibilityOpenerProvider.overrideWithValue(
            (_) => callCount++,
          ),
        ],
      );
      addTearDown(container.dispose);
      final opener = container.read(riscvCompatibilityOpenerProvider);
      expect(opener, isNotNull);
      expect(opener, isA<void Function(BuildContext)>());
      expect(callCount, 0);
    });

    test(
      'the default does not consult a tier at any '
      'LicenseTier x kBetaPeriod combination',
      () {
        // The seam mounts an ANALYSIS screen. Open core declares it null
        // for every tier, and the Pro overlay owns the gate — nothing on
        // the open-core side may read `licenseTierProvider` here, because
        // that is the first step towards a tier check landing on the
        // verdict path itself, and the verdict is correctness, which is free.
        for (final beta in <bool>[true, false]) {
          for (final tier in LicenseTier.values) {
            final container = ProviderContainer(
              overrides: [
                betaPeriodProvider.overrideWithValue(beta),
                licenseTierProvider.overrideWith((_) => tier),
              ],
            );
            addTearDown(container.dispose);
            expect(
              container.read(riscvCompatibilityOpenerProvider),
              isNull,
              reason: 'beta=$beta tier=$tier',
            );
          }
        }
      },
    );
  });
}
