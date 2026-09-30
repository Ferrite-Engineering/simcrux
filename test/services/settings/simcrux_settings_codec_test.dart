// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_settings/crux_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/domain/models/panel_layout_state.dart';
import 'package:simcrux/services/settings/simcrux_settings_codec.dart';

void main() {
  group('SimcruxSettingsCodec', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('load on a fresh prefs store returns defaults', () async {
      final prefs = await SharedPreferences.getInstance();
      final loaded = await const SimcruxSettingsCodec().load(prefs);
      expect(loaded, const AppSettings());
    });

    test('save then load round-trips recent project paths', () async {
      final prefs = await SharedPreferences.getInstance();
      const codec = SimcruxSettingsCodec();
      const settings = AppSettings(
        recentProjectPaths: ['/proj/a/simcrux.yaml', '/proj/b/simcrux.yaml'],
      );
      await codec.save(prefs, settings);

      final loaded = await codec.load(prefs);
      expect(loaded.recentProjectPaths, [
        '/proj/a/simcrux.yaml',
        '/proj/b/simcrux.yaml',
      ]);
    });

    test('autoCheckForUpdates defaults to on', () async {
      final prefs = await SharedPreferences.getInstance();
      final loaded = await const SimcruxSettingsCodec().load(prefs);
      expect(loaded.autoCheckForUpdates, isTrue);
    });

    test('save then load round-trips autoCheckForUpdates = false', () async {
      final prefs = await SharedPreferences.getInstance();
      const codec = SimcruxSettingsCodec();
      const settings = AppSettings(autoCheckForUpdates: false);
      await codec.save(prefs, settings);

      expect((await codec.load(prefs)).autoCheckForUpdates, isFalse);
      expect(prefs.getBool('simcrux.autoCheckForUpdates'), isFalse);
    });

    test('save then load round-trips autoCheckForUpdates = true', () async {
      final prefs = await SharedPreferences.getInstance();
      const codec = SimcruxSettingsCodec();
      await codec.save(prefs, const AppSettings(autoCheckForUpdates: false));
      await codec.save(prefs, const AppSettings());

      expect((await codec.load(prefs)).autoCheckForUpdates, isTrue);
    });

    test('autoRunOnOpen defaults to OFF', () async {
      // Opening a config must not start the
      // regression. An absent key is a user who never opted in.
      final prefs = await SharedPreferences.getInstance();
      final loaded = await const SimcruxSettingsCodec().load(prefs);
      expect(loaded.autoRunOnOpen, isFalse);
    });

    test('allowProjectDefinedTooling defaults to OFF', () async {
      // An absent key is a user who never said a project file may
      // choose which binary SimCrux spawns, or its environment.
      final prefs = await SharedPreferences.getInstance();
      final loaded = await const SimcruxSettingsCodec().load(prefs);
      expect(loaded.allowProjectDefinedTooling, isFalse);
    });

    test('round-trips allowProjectDefinedTooling both ways', () async {
      final prefs = await SharedPreferences.getInstance();
      const codec = SimcruxSettingsCodec();
      await codec.save(
        prefs,
        const AppSettings(allowProjectDefinedTooling: true),
      );
      expect((await codec.load(prefs)).allowProjectDefinedTooling, isTrue);
      expect(prefs.getBool('simcrux.allowProjectDefinedTooling'), isTrue);

      await codec.save(prefs, const AppSettings());
      expect((await codec.load(prefs)).allowProjectDefinedTooling, isFalse);
    });

    test('save then load round-trips autoRunOnOpen = true', () async {
      final prefs = await SharedPreferences.getInstance();
      const codec = SimcruxSettingsCodec();
      await codec.save(prefs, const AppSettings(autoRunOnOpen: true));

      expect((await codec.load(prefs)).autoRunOnOpen, isTrue);
      expect(prefs.getBool('simcrux.autoRunOnOpen'), isTrue);
    });

    test('save then load round-trips autoRunOnOpen back to false', () async {
      final prefs = await SharedPreferences.getInstance();
      const codec = SimcruxSettingsCodec();
      await codec.save(prefs, const AppSettings(autoRunOnOpen: true));
      await codec.save(prefs, const AppSettings());

      expect((await codec.load(prefs)).autoRunOnOpen, isFalse);
    });

    test(
      'broadcastSelectionOnCrossProbe defaults to ON when the key is absent',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final loaded = await const SimcruxSettingsCodec().load(prefs);
        expect(loaded.broadcastSelectionOnCrossProbe, isTrue);
      },
    );

    test(
      'save then load round-trips broadcastSelectionOnCrossProbe = false',
      () async {
        final prefs = await SharedPreferences.getInstance();
        const codec = SimcruxSettingsCodec();
        const settings = AppSettings(broadcastSelectionOnCrossProbe: false);
        await codec.save(prefs, settings);

        expect(
          (await codec.load(prefs)).broadcastSelectionOnCrossProbe,
          isFalse,
        );
        expect(
          prefs.getBool('simcrux.broadcastSelectionOnCrossProbe'),
          isFalse,
        );
      },
    );

    test(
      'a persisted false survives a full round-trip with other fields',
      () async {
        final prefs = await SharedPreferences.getInstance();
        const codec = SimcruxSettingsCodec();
        const settings = AppSettings(
          autoCheckForUpdates: false,
          autoRunOnOpen: true,
          broadcastSelectionOnCrossProbe: false,
          recentProjectPaths: ['/proj/a/simcrux.yaml'],
          cxpServerPort: 54999,
        );
        await codec.save(prefs, settings);

        final loaded = await codec.load(prefs);
        expect(loaded, settings);
      },
    );

    test('save then load round-trips a non-default core field', () async {
      final prefs = await SharedPreferences.getInstance();
      const codec = SimcruxSettingsCodec();
      final settings = const AppSettings().copyWith(
        core: const CoreSettings.defaults().copyWith(locale: 'ja'),
      );
      await codec.save(prefs, settings);

      final loaded = await codec.load(prefs);
      expect(loaded.locale, 'ja');
    });

    test(
      'malformed recentProjectPaths JSON falls back to empty list',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'simcrux.recentProjectPaths': 'not a json array',
        });
        final prefs = await SharedPreferences.getInstance();
        final loaded = await const SimcruxSettingsCodec().load(prefs);
        expect(loaded.recentProjectPaths, isEmpty);
      },
    );

    test('non-string entries in recentProjectPaths are filtered out', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'simcrux.recentProjectPaths': '["/a", 42, null, "/b"]',
      });
      final prefs = await SharedPreferences.getInstance();
      final loaded = await const SimcruxSettingsCodec().load(prefs);
      expect(loaded.recentProjectPaths, ['/a', '/b']);
    });

    test('save then load round-trips panel layout', () async {
      final prefs = await SharedPreferences.getInstance();
      const codec = SimcruxSettingsCodec();
      const settings = AppSettings(
        panelLayout: PanelLayoutState(
          testBrowserVisible: false,
          logPanelVisible: false,
          testBrowserFraction: 0.18,
          runDetailsFraction: 0.32,
          logPanelFraction: 0.4,
        ),
      );
      await codec.save(prefs, settings);

      final loaded = await codec.load(prefs);
      expect(loaded.panelLayout, equals(settings.panelLayout));
    });

    test('out-of-range panel fractions fall back to defaults', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'simcrux.panel.testBrowserFraction': 1.5,
        'simcrux.panel.runDetailsFraction': -0.5,
        'simcrux.panel.logPanelFraction': double.nan,
      });
      final prefs = await SharedPreferences.getInstance();
      final loaded = await const SimcruxSettingsCodec().load(prefs);
      expect(
        loaded.panelLayout.testBrowserFraction,
        equals(PanelLayoutState.defaultLeftFraction),
      );
      expect(
        loaded.panelLayout.runDetailsFraction,
        equals(PanelLayoutState.defaultRightFraction),
      );
      expect(
        loaded.panelLayout.logPanelFraction,
        equals(PanelLayoutState.defaultBottomFraction),
      );
    });
  });
}
