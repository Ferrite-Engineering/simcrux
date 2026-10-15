// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/models/panel_layout_state.dart';
import 'package:simcrux/features/panel_layout/providers/panel_layout_provider.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/services/settings/simcrux_settings_codec.dart';

Future<ProviderContainer> _makeContainer([
  Map<String, Object> stored = const <String, Object>{},
]) async {
  SharedPreferences.setMockInitialValues(stored);
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
      expect(settings.panelLayout.logPanelVisible, isTrue);
      expect(settings.panelLayout.logPanelChoiceMade, isTrue);
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
  group('Log panel visibility', () {
    test('starts collapsed with no choice', () async {
      final container = await _makeContainer();
      addTearDown(container.dispose);
      final layout = container.read(panelLayoutProvider);
      expect(layout.logPanelVisible, isFalse);
      expect(layout.logPanelChoiceMade, isFalse);
    });

    test(
      'the first selection reveals it, without recording a choice',
      () async {
        final container = await _makeContainer();
        addTearDown(container.dispose);

        await container
            .read(panelLayoutProvider.notifier)
            .revealLogPanelForSelection();

        final layout = container.read(panelLayoutProvider);
        expect(layout.logPanelVisible, isTrue);
        expect(layout.logPanelChoiceMade, isFalse);
      },
    );

    test(
      'the reveal is not persisted as a choice: next launch is collapsed',
      () async {
        final container = await _makeContainer();
        addTearDown(container.dispose);
        final notifier = container.read(panelLayoutProvider.notifier);
        await notifier.revealLogPanelForSelection();
        // An unrelated save writes every panel key again.
        await notifier.toggleTestBrowser();

        final prefs = await SharedPreferences.getInstance();
        final relaunched = (await const SimcruxSettingsCodec().load(
          prefs,
        )).panelLayout;
        expect(relaunched.logPanelVisible, isFalse);
        expect(relaunched.logPanelChoiceMade, isFalse);
      },
    );

    test('reveals at most once per session', () async {
      final container = await _makeContainer();
      addTearDown(container.dispose);
      final notifier = container.read(panelLayoutProvider.notifier);

      await notifier.revealLogPanelForSelection();
      // Closing it is an explicit choice; a later selection must not undo it.
      await notifier.setLogPanelVisible(visible: false);
      await notifier.revealLogPanelForSelection();

      final layout = container.read(panelLayoutProvider);
      expect(layout.logPanelVisible, isFalse);
      expect(layout.logPanelChoiceMade, isTrue);
    });

    test('the one reveal survives settings rebuilding the notifier', () async {
      final container = await _makeContainer();
      addTearDown(container.dispose);
      final notifier = container.read(panelLayoutProvider.notifier);
      await notifier.revealLogPanelForSelection();
      await notifier.toggleRunDetails(); // settings change -> build() reruns
      expect(container.read(panelLayoutProvider).logPanelVisible, isTrue);
    });

    test('never reveals once the user has chosen (hidden)', () async {
      final container = await _makeContainer(<String, Object>{
        'simcrux.panel.logPanelVisible': false,
        'simcrux.panel.logPanelChoice': true,
      });
      addTearDown(container.dispose);

      await container
          .read(panelLayoutProvider.notifier)
          .revealLogPanelForSelection();

      expect(container.read(panelLayoutProvider).logPanelVisible, isFalse);
    });

    test('an existing install that hid the panel keeps it hidden', () async {
      final container = await _makeContainer(<String, Object>{
        'simcrux.panel.logPanelVisible': false,
      });
      addTearDown(container.dispose);

      await container
          .read(panelLayoutProvider.notifier)
          .revealLogPanelForSelection();

      final layout = container.read(panelLayoutProvider);
      expect(layout.logPanelVisible, isFalse);
      expect(layout.logPanelChoiceMade, isTrue);
    });

    test('an explicit visible choice starts open and stays a choice', () async {
      final container = await _makeContainer(<String, Object>{
        'simcrux.panel.logPanelVisible': true,
        'simcrux.panel.logPanelChoice': true,
      });
      addTearDown(container.dispose);
      final layout = container.read(panelLayoutProvider);
      expect(layout.logPanelVisible, isTrue);
      expect(layout.logPanelChoiceMade, isTrue);
    });

    test('toggling records a choice', () async {
      final container = await _makeContainer();
      addTearDown(container.dispose);
      await container.read(panelLayoutProvider.notifier).toggleLogPanel();
      expect(container.read(panelLayoutProvider).logPanelChoiceMade, isTrue);
    });

    test('setLogPanelVisible records a choice, either way', () async {
      for (final visible in [true, false]) {
        final container = await _makeContainer();
        addTearDown(container.dispose);
        await container
            .read(panelLayoutProvider.notifier)
            .setLogPanelVisible(visible: visible);
        final layout = container.read(panelLayoutProvider);
        expect(layout.logPanelVisible, visible);
        expect(layout.logPanelChoiceMade, isTrue);
      }
    });

    test('resizing is not a visibility choice', () async {
      final container = await _makeContainer();
      addTearDown(container.dispose);
      final notifier = container.read(panelLayoutProvider.notifier);

      await notifier.setLogPanelFraction(0.45);
      expect(container.read(panelLayoutProvider).logPanelChoiceMade, isFalse);

      // ...so the panel still reveals afterwards.
      await notifier.revealLogPanelForSelection();
      expect(container.read(panelLayoutProvider).logPanelVisible, isTrue);
    });
  });
}
