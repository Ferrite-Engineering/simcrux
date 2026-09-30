// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Static-shaped conformance guard: the Settings rail's actual RENDERED
// category order must be a strictly-increasing-index subsequence of
// `CruxSettingsCategoryId.canonicalOrder` (crux_settings_ui). All four
// suite products share one rail order so their Settings dialogs read the
// same; until categories carried a stable `CruxSettingsCategoryId` nothing
// could assert it, and `settings_screen.dart` simply built its category
// list in the order someone last left it in.
//
// This does not re-derive the order by reading source text — it pumps the
// real `SettingsBody` widget and reads the actual `CruxSettingsMasterDetail`
// it renders, so a future edit that reorders the literal category list in
// `settings_screen.dart` is caught by running the app, not by grep.

import 'dart:io';

import 'package:crux_settings/crux_settings.dart';
import 'package:crux_settings_ui/crux_settings_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/settings/screens/settings_screen.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/settings/simcrux_settings_codec.dart';

/// Cross-platform fake so `ColorThemeSection`'s
/// `getApplicationSupportDirectory()` call gets a writable temp dir instead
/// of throwing `MissingPluginException` (copied from
/// `settings_screen_test.dart` — see its comment for why this is needed on
/// Windows CI).
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this._root);

  final Directory _root;

  @override
  Future<String?> getApplicationSupportPath() async => _root.path;

  @override
  Future<String?> getTemporaryPath() async => _root.path;

  @override
  Future<String?> getApplicationDocumentsPath() async => _root.path;

  @override
  Future<String?> getApplicationCachePath() async => _root.path;
}

void main() {
  late Directory tmpDir;
  late PathProviderPlatform priorPathProvider;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmpDir = Directory.systemTemp.createTempSync(
      'simcrux_settings_rail_order_test',
    );
    priorPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(tmpDir);
  });

  tearDown(() {
    PathProviderPlatform.instance = priorPathProvider;
    if (tmpDir.existsSync()) {
      tmpDir.deleteSync(recursive: true);
    }
  });

  testWidgets(
    'the rendered settings-rail id order is a subsequence of '
    'CruxSettingsCategoryId.canonicalOrder',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(960, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsServiceProvider.overrideWithValue(
              SettingsService<AppSettings>(
                const SimcruxSettingsCodec(),
                prefsOverride: prefs,
              ),
            ),
          ],
          child: const MaterialApp(
            localizationsDelegates: L10N.localizationsDelegates,
            supportedLocales: L10N.supportedLocales,
            home: SettingsScreen(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);

      final masterDetail = tester.widget<CruxSettingsMasterDetail>(
        find.byType(CruxSettingsMasterDetail),
      );
      final renderedIds = masterDetail.categories
          .map((c) => c.id)
          .toList(growable: false);

      // Not vacuous: a broken provider wiring or an empty category list
      // would make every assertion below pass trivially.
      expect(
        renderedIds,
        isNotEmpty,
        reason:
            'SettingsBody rendered zero categories — the settings provider '
            'wiring is broken, not conforming',
      );

      // Every id SimCrux renders must actually be a canonical id (a typo'd
      // or ad-hoc id would otherwise silently fall out of the subsequence
      // check below rather than failing loudly).
      for (final id in renderedIds) {
        expect(
          CruxSettingsCategoryId.canonicalOrder,
          contains(id),
          reason:
              'rendered settings category id "$id" is not in '
              'CruxSettingsCategoryId.canonicalOrder — either it is a typo, '
              'or a new canonical id needs adding to crux_settings_ui first',
        );
      }

      // Strictly-increasing-index subsequence: SimCrux's own categories may
      // skip canonical ids it does not implement (e.g. fileHandling,
      // orientation, remoteControl, extensions, ai are WaveCrux-only), but
      // whichever ids it does render must appear in the SAME relative order
      // canonicalOrder prescribes — never out of order.
      var lastIndex = -1;
      for (final id in renderedIds) {
        final index = CruxSettingsCategoryId.canonicalOrder.indexOf(id);
        expect(
          index,
          greaterThan(lastIndex),
          reason:
              'settings rail order violation: "$id" (canonical index '
              '$index) rendered after something with canonical index '
              '$lastIndex or later — rendered order was '
              '${renderedIds.join(" > ")}',
        );
        lastIndex = index;
      }
    },
  );
}
