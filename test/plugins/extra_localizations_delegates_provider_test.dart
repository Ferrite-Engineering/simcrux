// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/plugins/extra_localizations_delegates_provider.dart';

void main() {
  group('extraLocalizationsDelegatesProvider', () {
    test('open-core default is an empty list', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(extraLocalizationsDelegatesProvider), isEmpty);
    });

    test('overlay override surfaces additional delegates', () {
      final container = ProviderContainer(
        overrides: [
          extraLocalizationsDelegatesProvider.overrideWithValue(
            <LocalizationsDelegate<Object?>>[
              const _FakeDelegate(),
            ],
          ),
        ],
      );
      addTearDown(container.dispose);

      final delegates = container.read(extraLocalizationsDelegatesProvider);
      expect(delegates, hasLength(1));
      expect(delegates.first, isA<_FakeDelegate>());
    });
  });
}

class _FakeDelegate extends LocalizationsDelegate<_FakeLocalizations> {
  const _FakeDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<_FakeLocalizations> load(Locale locale) async => _FakeLocalizations();

  @override
  bool shouldReload(LocalizationsDelegate<_FakeLocalizations> old) => false;
}

class _FakeLocalizations {}
