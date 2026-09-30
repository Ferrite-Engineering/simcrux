// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_settings/crux_settings.dart';
import 'package:crux_settings_ui/crux_settings_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/settings/screens/settings_screen.dart';
import 'package:simcrux/features/settings/widgets/color_theme_section.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/settings/simcrux_settings_codec.dart';

/// Cross-platform fake so the Appearance section's `ColorThemeSection`, which
/// resolves `getApplicationSupportDirectory()` for its color-pack directory,
/// gets a writable temp dir instead of throwing `MissingPluginException`.
///
/// `flutter test` registers no real path_provider plugin on Windows, so the
/// unmocked call is red on windows-latest (Linux's pure-Dart
/// path_provider_linux masks the same call). The fake makes the test
/// platform-independent.
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

Future<Widget> _wrap({
  Locale locale = const Locale('en'),
  List<Override> extraOverrides = const [],
}) async {
  final prefs = await SharedPreferences.getInstance();
  return ProviderScope(
    overrides: [
      settingsServiceProvider.overrideWithValue(
        SettingsService<AppSettings>(
          const SimcruxSettingsCodec(),
          prefsOverride: prefs,
        ),
      ),
      ...extraOverrides,
    ],
    child: MaterialApp(
      locale: locale,
      localizationsDelegates: L10N.localizationsDelegates,
      supportedLocales: L10N.supportedLocales,
      home: const SettingsScreen(),
    ),
  );
}

void main() {
  late Directory tmpDir;
  late PathProviderPlatform priorPathProvider;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmpDir = Directory.systemTemp.createTempSync(
      'simcrux_settings_screen_test',
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

  testWidgets('uses the shared dual-pane shell (rail + detail) when wide', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(960, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(await _wrap());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(CruxSettingsMasterDetail), findsOneWidget);
    expect(find.byType(VerticalDivider), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('collapses to a single column (no divider) when narrow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(await _wrap());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(CruxSettingsMasterDetail), findsOneWidget);
    expect(find.byType(VerticalDivider), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('locale sweep renders without exception in en/zh_CN/zh/ja/ko', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(960, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    for (final locale in const [
      Locale('en'),
      Locale('zh', 'CN'),
      Locale('zh'),
      Locale('ja'),
      Locale('ko'),
    ]) {
      await tester.pumpWidget(await _wrap(locale: locale));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull, reason: '$locale');
      expect(
        find.byType(CruxSettingsMasterDetail),
        findsOneWidget,
        reason: '$locale',
      );
    }
  });

  testWidgets(
    'Appearance section shows the color-theme picker and no theme-mode chips',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(960, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(await _wrap());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final l10n = L10N.of(tester.element(find.byType(SettingsScreen)));
      await tester.tap(find.text(l10n.settingsAppearanceSection));
      await tester.pumpAndSettle();

      // Brightness follows the color preset (2026-07-24 consistency pass);
      // the inert system/light/dark selector must stay deleted.
      expect(find.byType(ColorThemeSection), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('renders the localized settings-load error', (tester) async {
    await tester.pumpWidget(
      await _wrap(
        extraOverrides: [
          appSettingsProvider.overrideWith(_ThrowingAppSettingsNotifier.new),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final l10n = L10N.of(tester.element(find.byType(SettingsScreen)));
    expect(
      find.text(l10n.settingsLoadFailed('Exception: boom')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

class _ThrowingAppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => throw Exception('boom');
}
