// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_actions_extensions.dart';

void main() {
  group('extraDashboardActionsProvider', () {
    test('open-core default is an empty list', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(extraDashboardActionsProvider), isEmpty);
    });

    test('override surfaces caller-supplied widgets in order', () {
      const a = SizedBox(width: 1);
      const b = SizedBox(width: 2);
      final container = ProviderContainer(
        overrides: [
          extraDashboardActionsProvider.overrideWithValue(<Widget>[a, b]),
        ],
      );
      addTearDown(container.dispose);
      final actions = container.read(extraDashboardActionsProvider);
      expect(actions, hasLength(2));
      expect(identical(actions[0], a), isTrue);
      expect(identical(actions[1], b), isTrue);
    });
  });
}
