// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/config/providers/config_loader_provider.dart';
import 'package:simcrux/services/config/config_loader.dart';

void main() {
  group('configLoaderProvider', () {
    test('returns a real ConfigLoader by default', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(configLoaderProvider), isA<ConfigLoader>());
    });

    test('honours override for injected loader', () {
      final fakeLoader = ConfigLoader(
        readFile: (_) async => '''
version: "1"
suites:
  s:
    simulator: icarus
    tests:
      - name: t
        top: tb
''',
      );
      final container = ProviderContainer(
        overrides: [
          configLoaderProvider.overrideWithValue(fakeLoader),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(configLoaderProvider), same(fakeLoader));
    });
  });
}
