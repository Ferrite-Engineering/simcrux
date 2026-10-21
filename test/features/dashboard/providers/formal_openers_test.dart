// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/dashboard/providers/formal_openers.dart';

// The four Pro formal seams. Each is null in open core, for every tier: the
// Pro overlay owns the gate, and nothing on the open-core side may read a
// tier here, because the verdicts the screens analyse are free.
void main() {
  final seams = <String, Provider<FormalScreenOpener?>>{
    'formalPropertiesOpenerProvider': formalPropertiesOpenerProvider,
    'formalHistoryOpenerProvider': formalHistoryOpenerProvider,
    'pretraceAnalysisOpenerProvider': pretraceAnalysisOpenerProvider,
    'eqyExplorerOpenerProvider': eqyExplorerOpenerProvider,
  };

  for (final MapEntry(key: name, value: seam) in seams.entries) {
    group(name, () {
      test('the open-core default is null at every tier, beta on or off', () {
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
              container.read(seam),
              isNull,
              reason: 'beta=$beta tier=$tier',
            );
          }
        }
      });

      test('an override surfaces a callable opener', () {
        var calls = 0;
        final container = ProviderContainer(
          overrides: [seam.overrideWithValue((_) => calls++)],
        );
        addTearDown(container.dispose);
        final opener = container.read(seam);
        expect(opener, isA<void Function(BuildContext)>());
        expect(calls, 0);
      });
    });
  }
}
