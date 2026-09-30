// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/models/panel_layout_state.dart';
import 'package:simcrux/features/panel_layout/providers/panel_layout_provider.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';

Future<ProviderContainer> _makeContainer() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final container = ProviderContainer();
  // Force the AppSettings to finish loading so subsequent
  // panelLayoutProvider reads see the persisted state.
  await container.read(appSettingsProvider.future);
  return container;
}

void main() {
  group('panelLayoutProvider', () {
    test('initial state matches defaults', () async {
      final container = await _makeContainer();
      addTearDown(container.dispose);
      expect(container.read(panelLayoutProvider), const PanelLayoutState());
    });

    test('toggleTestBrowser flips visibility', () async {
      final container = await _makeContainer();
      addTearDown(container.dispose);

      final notifier = container.read(panelLayoutProvider.notifier);
      expect(container.read(panelLayoutProvider).testBrowserVisible, isTrue);

      await notifier.toggleTestBrowser();
      expect(container.read(panelLayoutProvider).testBrowserVisible, isFalse);

      await notifier.toggleTestBrowser();
      expect(container.read(panelLayoutProvider).testBrowserVisible, isTrue);
    });

    test('setTestBrowserFraction clamps below 0.05', () async {
      final container = await _makeContainer();
      addTearDown(container.dispose);

      await container
          .read(panelLayoutProvider.notifier)
          .setTestBrowserFraction(0.01);
      expect(
        container.read(panelLayoutProvider).testBrowserFraction,
        equals(0.05),
      );
    });

    test('setRunDetailsFraction clamps above 0.6', () async {
      final container = await _makeContainer();
      addTearDown(container.dispose);

      await container
          .read(panelLayoutProvider.notifier)
          .setRunDetailsFraction(0.95);
      expect(
        container.read(panelLayoutProvider).runDetailsFraction,
        equals(0.6),
      );
    });

    test('setLogPanelFraction passes through valid values', () async {
      final container = await _makeContainer();
      addTearDown(container.dispose);

      await container
          .read(panelLayoutProvider.notifier)
          .setLogPanelFraction(0.45);
      expect(
        container.read(panelLayoutProvider).logPanelFraction,
        equals(0.45),
      );
    });

    test('mutations persist through AppSettings', () async {
      final container = await _makeContainer();
      addTearDown(container.dispose);

      await container.read(panelLayoutProvider.notifier).toggleLogPanel();
      // The AppSettings notifier should reflect the same change.
      final settings = container.read(appSettingsProvider).value!;
      expect(settings.panelLayout.logPanelVisible, isFalse);
    });

    test('resetToDefaults reverts everything', () async {
      final container = await _makeContainer();
      addTearDown(container.dispose);

      final notifier = container.read(panelLayoutProvider.notifier);
      await notifier.toggleTestBrowser();
      await notifier.setRunDetailsFraction(0.45);
      await notifier.resetToDefaults();

      expect(container.read(panelLayoutProvider), const PanelLayoutState());
    });
  });
}
