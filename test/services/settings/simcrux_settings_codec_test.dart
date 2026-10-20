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

    test(
      'maxTotalSimulators defaults to 4, round-trips, and is clamped',
      () async {
        final prefs = await SharedPreferences.getInstance();
        const codec = SimcruxSettingsCodec();
        expect((await codec.load(prefs)).maxTotalSimulators, 4);

        await codec.save(prefs, const AppSettings(maxTotalSimulators: 12));
        expect((await codec.load(prefs)).maxTotalSimulators, 12);
        expect(prefs.getInt('simcrux.maxTotalSimulators'), 12);

        // A hand-edited 0 would deadlock every run; a huge value is a typo.
        await prefs.setInt('simcrux.maxTotalSimulators', 0);
        expect((await codec.load(prefs)).maxTotalSimulators, 1);
        await prefs.setInt('simcrux.maxTotalSimulators', 100000);
        expect((await codec.load(prefs)).maxTotalSimulators, 64);
      },
    );

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
      'a save never touches the four CXP keys the shared settings own',
      () async {
        // The shared CXP settings save these under the product's prefix. A
        // second writer here would overwrite them with defaults on every
        // unrelated settings save (opening a project, toggling a panel).
        SharedPreferences.setMockInitialValues(<String, Object>{
          'simcrux.cxpServerEnabled': false,
          'simcrux.cxpServerPort': 54999,
          'simcrux.requestAttentionOnCrossProbe': false,
          'simcrux.broadcastSelectionOnCrossProbe': false,
        });
        final prefs = await SharedPreferences.getInstance();
        const codec = SimcruxSettingsCodec();
        await codec.save(prefs, const AppSettings(autoRunOnOpen: true));

        expect(prefs.getBool('simcrux.cxpServerEnabled'), isFalse);
        expect(prefs.getInt('simcrux.cxpServerPort'), 54999);
        expect(prefs.getBool('simcrux.requestAttentionOnCrossProbe'), isFalse);
        expect(
          prefs.getBool('simcrux.broadcastSelectionOnCrossProbe'),
          isFalse,
        );
      },
    );

    test(
      'a save does not write the CXP keys when they were never set',
      () async {
        final prefs = await SharedPreferences.getInstance();
        await const SimcruxSettingsCodec().save(prefs, const AppSettings());

        expect(prefs.containsKey('simcrux.cxpServerEnabled'), isFalse);
        expect(prefs.containsKey('simcrux.cxpServerPort'), isFalse);
        expect(
          prefs.containsKey('simcrux.requestAttentionOnCrossProbe'),
          isFalse,
        );
        expect(
          prefs.containsKey('simcrux.broadcastSelectionOnCrossProbe'),
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
          recentProjectPaths: ['/proj/a/simcrux.yaml'],
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
          logPanelChoiceMade: true,
          testBrowserFraction: 0.18,
          runDetailsFraction: 0.32,
          logPanelFraction: 0.4,
        ),
      );
      await codec.save(prefs, settings);

      final loaded = await codec.load(prefs);
      expect(loaded.panelLayout, equals(settings.panelLayout));
    });

    group('Log panel choice', () {
      Future<PanelLayoutState> loadWith(Map<String, Object> stored) async {
        SharedPreferences.setMockInitialValues(stored);
        final prefs = await SharedPreferences.getInstance();
        return (await const SimcruxSettingsCodec().load(prefs)).panelLayout;
      }

      test('a fresh install starts collapsed with no choice', () async {
        final layout = await loadWith(<String, Object>{});
        expect(layout.logPanelVisible, isFalse);
        expect(layout.logPanelChoiceMade, isFalse);
      });

      test(
        'old key false and no new key is an explicit hidden choice',
        () async {
          final layout = await loadWith(<String, Object>{
            'simcrux.panel.logPanelVisible': false,
          });
          expect(layout.logPanelVisible, isFalse);
          expect(layout.logPanelChoiceMade, isTrue);
        },
      );

      test('old key true and no new key is no choice', () async {
        final layout = await loadWith(<String, Object>{
          'simcrux.panel.logPanelVisible': true,
        });
        expect(layout.logPanelVisible, isFalse);
        expect(layout.logPanelChoiceMade, isFalse);
      });

      test('an explicit visible choice round-trips', () async {
        final prefs = await SharedPreferences.getInstance();
        const codec = SimcruxSettingsCodec();
        const chosen = PanelLayoutState(
          logPanelVisible: true,
          logPanelChoiceMade: true,
        );
        await codec.save(prefs, const AppSettings(panelLayout: chosen));
        expect(prefs.getBool('simcrux.panel.logPanelChoice'), isTrue);
        expect((await codec.load(prefs)).panelLayout, equals(chosen));
      });

      test('an explicit hidden choice round-trips', () async {
        final prefs = await SharedPreferences.getInstance();
        const codec = SimcruxSettingsCodec();
        const chosen = PanelLayoutState(logPanelChoiceMade: true);
        await codec.save(prefs, const AppSettings(panelLayout: chosen));
        expect((await codec.load(prefs)).panelLayout, equals(chosen));
      });

      test(
        'an automatic reveal is not stored as a decision: the next launch '
        'starts collapsed with no choice',
        () async {
          final prefs = await SharedPreferences.getInstance();
          const codec = SimcruxSettingsCodec();
          await codec.save(
            prefs,
            const AppSettings(
              panelLayout: PanelLayoutState(logPanelVisible: true),
            ),
          );
          // Saved without a choice, then read back: not the migration path
          // ("old false, no new key"), because the new key is always written.
          expect(prefs.getBool('simcrux.panel.logPanelChoice'), isFalse);
          final layout = (await codec.load(prefs)).panelLayout;
          expect(layout.logPanelVisible, isFalse);
          expect(layout.logPanelChoiceMade, isFalse);
        },
      );

      test(
        'a saved default layout does not migrate into a hidden choice',
        () async {
          final prefs = await SharedPreferences.getInstance();
          const codec = SimcruxSettingsCodec();
          await codec.save(prefs, const AppSettings());
          final layout = (await codec.load(prefs)).panelLayout;
          expect(layout.logPanelChoiceMade, isFalse);
        },
      );

      test('with no choice stored, a stored visible true is ignored', () async {
        final layout = await loadWith(<String, Object>{
          'simcrux.panel.logPanelVisible': true,
          'simcrux.panel.logPanelChoice': false,
        });
        expect(layout.logPanelVisible, isFalse);
        expect(layout.logPanelChoiceMade, isFalse);
      });
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
