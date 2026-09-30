// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_settings_ui/crux_settings_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/settings/providers/settings_extensions.dart';

void main() {
  group('extraSettingsSectionsProvider', () {
    test('open-core default is the empty list', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(extraSettingsSectionsProvider), isEmpty);
    });

    test('overrideWithValue replaces the registered list '
        '(suite-shared CruxSettingsExtraCategory shape)', () {
      const ext = CruxSettingsExtraCategory(
        id: 'pro.test',
        icon: Icons.extension,
        labelBuilder: _proLabel,
        bodyBuilder: _proBody,
      );
      final container = ProviderContainer(
        overrides: [
          extraSettingsSectionsProvider.overrideWithValue(
            <CruxSettingsExtraCategory>[ext],
          ),
        ],
      );
      addTearDown(container.dispose);
      final result = container.read(extraSettingsSectionsProvider);
      expect(result, hasLength(1));
      expect(result.single.id, 'pro.test');
      expect(result.single.icon, Icons.extension);
    });
  });
}

String _proLabel(BuildContext context) => 'Pro';

Widget _proBody(BuildContext context) =>
    const SizedBox(key: ValueKey('pro-body'));
