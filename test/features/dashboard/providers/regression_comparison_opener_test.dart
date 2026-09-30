// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/dashboard/providers/regression_comparison_opener.dart';

void main() {
  group('regressionComparisonOpenerProvider', () {
    test('open-core default is null (no opener registered)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(regressionComparisonOpenerProvider), isNull);
    });

    test('override surfaces a callable opener', () {
      var callCount = 0;
      final container = ProviderContainer(
        overrides: [
          regressionComparisonOpenerProvider.overrideWithValue(
            (_) => callCount++,
          ),
        ],
      );
      addTearDown(container.dispose);
      final opener = container.read(regressionComparisonOpenerProvider);
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
