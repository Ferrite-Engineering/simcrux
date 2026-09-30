// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/dashboard/providers/seed_failure_heatmap_opener.dart';

void main() {
  group('seedFailureHeatmapOpenerProvider', () {
    test('open-core default is null (no opener registered)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(seedFailureHeatmapOpenerProvider), isNull);
    });

    test('override surfaces a callable opener', () {
      var callCount = 0;
      final container = ProviderContainer(
        overrides: [
          seedFailureHeatmapOpenerProvider.overrideWithValue(
            (_) => callCount++,
          ),
        ],
      );
      addTearDown(container.dispose);
      final opener = container.read(seedFailureHeatmapOpenerProvider);
      expect(opener, isNotNull);
      // Cannot synthesize a real BuildContext in a unit test; the
      // contract guarantee under test is that the provider returns
      // a callable when an override is registered. The Pro overlay's
      // widget tests exercise the BuildContext-bearing path
      // end-to-end.
      expect(opener, isA<void Function(BuildContext)>());
      expect(callCount, 0);
    });
  });
}
