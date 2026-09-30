// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/flaky_detection/providers/flaky_tests_panel_opener.dart';

void main() {
  group('flakyTestsPanelOpenerProvider', () {
    test('open-core default is null (no opener registered)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(flakyTestsPanelOpenerProvider), isNull);
    });

    test('override surfaces a callable opener', () {
      var callCount = 0;
      final container = ProviderContainer(
        overrides: [
          flakyTestsPanelOpenerProvider.overrideWithValue((_) => callCount++),
        ],
      );
      addTearDown(container.dispose);
      final opener = container.read(flakyTestsPanelOpenerProvider);
      expect(opener, isNotNull);
      // Cannot synthesize a real BuildContext in a unit test; the
      // contract under test is that an override surfaces a callable.
      // The Pro overlay's widget tests exercise the BuildContext path.
      expect(opener, isA<void Function(BuildContext)>());
      expect(callCount, 0);
    });
  });
}
