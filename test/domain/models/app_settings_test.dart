// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_settings/crux_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/app_settings.dart';

void main() {
  group('AppSettings', () {
    test('default constructor uses CoreSettings.defaults() and empty list', () {
      const settings = AppSettings();
      expect(settings.core, const CoreSettings.defaults());
      expect(settings.recentProjectPaths, isEmpty);
    });

    test('forwarder getters delegate to core', () {
      const settings = AppSettings();
      expect(settings.themeMode, settings.core.themeMode);
      expect(settings.locale, settings.core.locale);
      expect(settings.diagnosticsEnabled, settings.core.diagnosticsEnabled);
      expect(settings.restoreTabsOnLaunch, settings.core.restoreTabsOnLaunch);
    });

    test('copyWith replaces recentProjectPaths only', () {
      const settings = AppSettings();
      final updated = settings.copyWith(
        recentProjectPaths: const ['/a/proj/simcrux.yaml'],
      );
      expect(updated.recentProjectPaths, ['/a/proj/simcrux.yaml']);
      expect(updated.core, settings.core);
    });

    test('copyWith replaces core only', () {
      const settings = AppSettings();
      final updated = settings.copyWith(
        core: settings.core.copyWith(locale: 'ja'),
      );
      expect(updated.locale, 'ja');
      expect(updated.recentProjectPaths, settings.recentProjectPaths);
    });

    test('equality is value-based across core and recent paths', () {
      const a = AppSettings(
        recentProjectPaths: ['/a', '/b'],
      );
      const b = AppSettings(
        recentProjectPaths: ['/a', '/b'],
      );
      const c = AppSettings(
        recentProjectPaths: ['/a', '/b', '/c'],
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });

    test('equality is order-sensitive on recentProjectPaths', () {
      const a = AppSettings(recentProjectPaths: ['/a', '/b']);
      const b = AppSettings(recentProjectPaths: ['/b', '/a']);
      expect(a, isNot(equals(b)));
    });

    test('recentProjectsMax is documented as a stable constant', () {
      expect(AppSettings.recentProjectsMax, 10);
    });
  });

  group('AppSettings.autoCheckForUpdates', () {
    test('defaults to on', () {
      expect(const AppSettings().autoCheckForUpdates, isTrue);
    });

    test('copyWith replaces it', () {
      final off = const AppSettings().copyWith(autoCheckForUpdates: false);
      expect(off.autoCheckForUpdates, isFalse);
      expect(
        off.copyWith(autoCheckForUpdates: true).autoCheckForUpdates,
        isTrue,
      );
    });

    test('copyWith without the field preserves it', () {
      final off = const AppSettings().copyWith(autoCheckForUpdates: false);
      expect(off.copyWith(cxpServerPort: 54999).autoCheckForUpdates, isFalse);
    });

    test('participates in equality and hashCode', () {
      const on = AppSettings();
      const off = AppSettings(autoCheckForUpdates: false);
      expect(on, isNot(off));
      expect(on.hashCode, isNot(off.hashCode));
      expect(off, const AppSettings(autoCheckForUpdates: false));
    });
  });

  group('AppSettings.broadcastSelectionOnCrossProbe', () {
    test('defaults to on', () {
      expect(const AppSettings().broadcastSelectionOnCrossProbe, isTrue);
    });

    test('copyWith replaces it', () {
      final off = const AppSettings().copyWith(
        broadcastSelectionOnCrossProbe: false,
      );
      expect(off.broadcastSelectionOnCrossProbe, isFalse);
      expect(
        off
            .copyWith(broadcastSelectionOnCrossProbe: true)
            .broadcastSelectionOnCrossProbe,
        isTrue,
      );
    });

    test('copyWith without the field preserves it', () {
      final off = const AppSettings().copyWith(
        broadcastSelectionOnCrossProbe: false,
      );
      expect(
        off.copyWith(cxpServerPort: 54999).broadcastSelectionOnCrossProbe,
        isFalse,
      );
    });

    test('participates in equality and hashCode', () {
      const on = AppSettings();
      const off = AppSettings(broadcastSelectionOnCrossProbe: false);
      expect(on, isNot(off));
      expect(on.hashCode, isNot(off.hashCode));
      expect(off, const AppSettings(broadcastSelectionOnCrossProbe: false));
    });
  });
}
