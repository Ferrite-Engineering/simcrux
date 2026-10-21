// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'package:crux_settings_ui/crux_settings_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/settings/widgets/settings_engines_section.dart';
import 'package:simcrux/features/settings/widgets/settings_formal_tools_section.dart';
import 'package:simcrux/features/settings/widgets/settings_implementation_flow_section.dart';
import 'package:simcrux/features/settings/widgets/settings_simulators_section.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';
import 'package:simcrux/services/simulator/demo_simulator_driver.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

/// Settings > Engines: the slot NetCrux and LintCrux also title Engines,
/// with Simulators, Formal tools and Implementation flow as its groups.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<ProviderContainer> makeContainer({List<String>? engineIds}) async {
    final container = ProviderContainer(
      overrides: [
        if (engineIds != null)
          simulatorDriverRegistryProvider.overrideWithValue(
            SimulatorDriverRegistry({
              for (final id in engineIds) id: const DemoSimulatorDriver(),
            }),
          ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);
    return container;
  }

  Future<void> pump(
    WidgetTester tester,
    ProviderContainer container, {
    Locale? locale,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
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
              child: SettingsEnginesSection(settings: AppSettings()),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  L10N l10nOf(WidgetTester tester) =>
      L10N.of(tester.element(find.byType(Scaffold)));

  testWidgets('the shipped build shows one card, Simulators, and no empty '
      'Formal tools or Implementation flow card', (tester) async {
    final container = await makeContainer();
    await pump(tester, container);
    final l10n = l10nOf(tester);

    expect(find.byType(CruxSettingsSectionCard), findsOneWidget);
    expect(find.text(l10n.settingsSimulatorsSection), findsOneWidget);
    expect(find.text(l10n.settingsFormalToolsSection), findsNothing);
    expect(find.text(l10n.settingsImplementationFlowSection), findsNothing);
    expect(find.byType(SettingsSimulatorsSection), findsOneWidget);
  });

  testWidgets('a formal or flow engine gets its row in its own group, never '
      'under Simulators', (tester) async {
    final container = await makeContainer(
      engineIds: const ['icarus', 'sby', 'eqy', 'librelane', 'nextpnr'],
    );
    await pump(tester, container);
    final l10n = l10nOf(tester);

    expect(find.byType(CruxSettingsSectionCard), findsNWidgets(3));
    expect(find.text(l10n.settingsFormalToolsSection), findsOneWidget);
    expect(find.text(l10n.settingsImplementationFlowSection), findsOneWidget);

    Finder idIn(Type group, String id) =>
        find.descendant(of: find.byType(group), matching: find.text(id));

    expect(idIn(SettingsSimulatorsSection, 'icarus'), findsOneWidget);
    for (final id in kFormalToolEngineIds) {
      expect(idIn(SettingsFormalToolsSection, id), findsOneWidget);
      expect(idIn(SettingsSimulatorsSection, id), findsNothing, reason: id);
    }
    for (final id in kImplementationFlowEngineIds) {
      expect(idIn(SettingsImplementationFlowSection, id), findsOneWidget);
      expect(idIn(SettingsSimulatorsSection, id), findsNothing, reason: id);
    }
    // Each id is listed exactly once across the whole category.
    for (final id in const ['icarus', 'sby', 'eqy', 'librelane', 'nextpnr']) {
      expect(find.text(id), findsOneWidget, reason: id);
    }
  });

  testWidgets('a group shows only the engines this build registers', (
    tester,
  ) async {
    final container = await makeContainer(engineIds: const ['icarus', 'sby']);
    await pump(tester, container);
    final l10n = l10nOf(tester);

    expect(find.text('sby'), findsOneWidget);
    expect(find.text('eqy'), findsNothing);
    expect(find.text(l10n.settingsImplementationFlowSection), findsNothing);
  });

  test('the groups partition the engine ids', () {
    expect(
      kEngineIdsOutsideSimulators,
      <String>{...kFormalToolEngineIds, ...kImplementationFlowEngineIds},
    );
    expect(
      kFormalToolEngineIds.toSet().intersection(
        kImplementationFlowEngineIds.toSet(),
      ),
      isEmpty,
    );
  });

  testWidgets('the shipped registry lists no formal or flow engine yet, so '
      'nothing moved out of Simulators', (tester) async {
    final container = await makeContainer();
    final shipped = container
        .read(simulatorDriverRegistryProvider)
        .simulatorIds
        .toSet();
    expect(shipped.intersection(kEngineIdsOutsideSimulators), isEmpty);
  });

  testWidgets('every locale names the category and its groups, without '
      'overflow', (tester) async {
    final en = await L10N.delegate.load(const Locale('en'));
    expect(en.settingsEnginesSection, 'Engines');
    for (final locale in const [
      Locale('en'),
      Locale('zh', 'CN'),
      Locale('zh'),
      Locale('ja'),
      Locale('ko'),
    ]) {
      final l10n = await L10N.delegate.load(locale);
      for (final title in [
        l10n.settingsEnginesSection,
        l10n.settingsSimulatorsSection,
        l10n.settingsFormalToolsSection,
        l10n.settingsImplementationFlowSection,
      ]) {
        expect(title.trim(), isNotEmpty, reason: '$locale');
      }
      if (locale.languageCode != 'en') {
        expect(
          l10n.settingsFormalToolsSection,
          isNot(en.settingsFormalToolsSection),
          reason: '$locale',
        );
      }
      final container = await makeContainer(
        engineIds: const ['icarus', 'sby', 'librelane'],
      );
      await pump(tester, container, locale: locale);
      expect(tester.takeException(), isNull, reason: '$locale');
    }
  });
}
