// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_settings/crux_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/settings/widgets/settings_editor_section.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/settings/simcrux_settings_codec.dart';

Future<Widget> _wrap({Locale locale = const Locale('en')}) async {
  final prefs = await SharedPreferences.getInstance();
  return ProviderScope(
    overrides: [
      settingsServiceProvider.overrideWithValue(
        SettingsService<AppSettings>(
          const SimcruxSettingsCodec(),
          prefsOverride: prefs,
        ),
      ),
    ],
    child: MaterialApp(
      locale: locale,
      localizationsDelegates: const [
        L10N.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: L10N.supportedLocales,
      home: const Scaffold(
        body: SingleChildScrollView(
          child: SettingsEditorSection(settings: AppSettings()),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('SettingsEditorSection', () {
    testWidgets('renders the preset chips and the command template field', (
      tester,
    ) async {
      await tester.pumpWidget(await _wrap());
      await tester.pump();

      final l10n = L10N.of(tester.element(find.byType(Scaffold)));
      expect(find.text(l10n.settingsEditorPresetVscode), findsOneWidget);
      expect(find.text(l10n.settingsEditorPresetSublime), findsOneWidget);
      expect(find.text(l10n.settingsEditorPresetVim), findsOneWidget);
      expect(find.text(l10n.settingsEditorPresetEmacs), findsOneWidget);
      expect(find.text(l10n.settingsEditorPresetCustom), findsOneWidget);
      expect(find.text(l10n.settingsEditorCommandLabel), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);

      // The default template matches the VS Code preset, so its chip is
      // the selected one.
      final vscodeChip = tester.widget<ChoiceChip>(
        find.ancestor(
          of: find.text(l10n.settingsEditorPresetVscode),
          matching: find.byType(ChoiceChip),
        ),
      );
      expect(vscodeChip.selected, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping a preset chip updates the backing provider', (
      tester,
    ) async {
      await tester.pumpWidget(await _wrap());
      await tester.pump();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(SettingsEditorSection)),
      );
      // Let the AsyncNotifier hydrate so mutators see a loaded value.
      await container.read(appSettingsProvider.future);
      await tester.pump();

      final l10n = L10N.of(tester.element(find.byType(Scaffold)));
      await tester.tap(find.text(l10n.settingsEditorPresetVim));
      await tester.pump();

      expect(
        container.read(appSettingsProvider).value?.editorCommandTemplate,
        'vim +{line} {file}',
      );
      // The text field mirrors the applied template.
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        'vim +{line} {file}',
      );
    });

    testWidgets('locale sweep renders without exceptions', (tester) async {
      for (final locale in const [
        Locale('en'),
        Locale('zh', 'CN'),
        Locale('zh'),
        Locale('ja'),
        Locale('ko'),
      ]) {
        await tester.pumpWidget(await _wrap(locale: locale));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: '$locale');
      }
    });
  });
}
