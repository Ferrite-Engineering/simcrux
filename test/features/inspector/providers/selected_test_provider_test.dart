// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';

void main() {
  group('SelectedTestNotifier', () {
    test('builds with null and supports select/clear transitions', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(selectedTestIdProvider), isNull);
      container.read(selectedTestIdProvider.notifier).select('unit/alu_basic');
      expect(container.read(selectedTestIdProvider), 'unit/alu_basic');
      container.read(selectedTestIdProvider.notifier).clear();
      expect(container.read(selectedTestIdProvider), isNull);
    });
  });

  group('selectedTestProvider', () {
    test('returns null when no test is selected', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(selectedTestProvider), isNull);
    });
  });
}
