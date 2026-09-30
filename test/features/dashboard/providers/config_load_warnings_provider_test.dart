// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/dashboard/providers/config_load_warnings_provider.dart';

void main() {
  test('open core shows load advisories by default', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(showConfigLoadWarningsProvider), isTrue);
  });

  test('an overlay can hide them', () {
    final container = ProviderContainer(
      overrides: [showConfigLoadWarningsProvider.overrideWithValue(false)],
    );
    addTearDown(container.dispose);
    expect(container.read(showConfigLoadWarningsProvider), isFalse);
  });
}
