// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/settings/widgets/settings_simulators_section.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';

Widget _wrap({
  required ProviderContainer container,
  required AppSettings settings,
  Locale? locale,
}) {
  return UncontrolledProviderScope(
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
      home: Scaffold(
        body: SingleChildScrollView(
          child: SettingsSimulatorsSection(settings: settings),
        ),
      ),
    ),
  );
}

/// The path-override [TextField] in the row labelled [simulatorId].
Finder _fieldFor(String simulatorId) => find.descendant(
  of: find
      .ancestor(of: find.text(simulatorId), matching: find.byType(Row))
      .first,
  matching: find.byType(TextField),
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<ProviderContainer> makeContainer() async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);
    return container;
  }

  testWidgets('renders one path field per registered simulator', (
    tester,
  ) async {
    final container = await makeContainer();
    await tester.pumpWidget(
      _wrap(container: container, settings: const AppSettings()),
    );
    await tester.pump();

    final registry = container.read(simulatorDriverRegistryProvider);
    expect(registry.simulatorIds, isNotEmpty);
    for (final id in registry.simulatorIds) {
      expect(find.text(id), findsOneWidget, reason: id);
      expect(_fieldFor(id), findsOneWidget, reason: id);
    }
    final l10n = L10N.of(tester.element(find.byType(Scaffold)));
    expect(find.text(l10n.settingsSimulatorBinaryLabel), findsOneWidget);
  });

  testWidgets('pre-fills fields from the settings override map', (
    tester,
  ) async {
    final container = await makeContainer();
    const settings = AppSettings(
      simulatorBinaryOverrides: {'icarus': '/opt/iverilog/bin/vvp'},
    );
    await tester.pumpWidget(_wrap(container: container, settings: settings));
    await tester.pump();

    expect(find.text('/opt/iverilog/bin/vvp'), findsOneWidget);
    expect(
      tester.widget<TextField>(_fieldFor('icarus')).controller?.text,
      '/opt/iverilog/bin/vvp',
    );
    // Other simulators stay blank.
    expect(
      tester.widget<TextField>(_fieldFor('verilator')).controller?.text,
      isEmpty,
    );
  });

  testWidgets('submitting a path persists the override for that simulator', (
    tester,
  ) async {
    final container = await makeContainer();
    await tester.pumpWidget(
      _wrap(container: container, settings: const AppSettings()),
    );
    await tester.pump();

    await tester.enterText(_fieldFor('verilator'), '/opt/verilator/bin');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await container.read(appSettingsProvider.future);

    expect(
      container.read(appSettingsProvider).value!.simulatorBinaryOverrides,
      {'verilator': '/opt/verilator/bin'},
    );
  });

  testWidgets('submitting an empty value removes the override', (
    tester,
  ) async {
    final container = await makeContainer();
    const settings = AppSettings(
      simulatorBinaryOverrides: {'icarus': '/opt/iverilog/bin/vvp'},
    );
    await tester.pumpWidget(_wrap(container: container, settings: settings));
    await tester.pump();

    await tester.enterText(_fieldFor('icarus'), '');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await container.read(appSettingsProvider.future);

    expect(
      container.read(appSettingsProvider).value!.simulatorBinaryOverrides,
      isNot(contains('icarus')),
    );
  });

  group('project-defined tooling switch', () {
    // The user-facing half of the `simcrux.yaml` code-execution gate:
    // `simulators.<id>.path` / `.env` and the `riscv.*.command` argv
    // lists are refused until this is on. See
    // `AppSettings.allowProjectDefinedTooling`.
    testWidgets('is OFF for default settings', (tester) async {
      final container = await makeContainer();
      await tester.pumpWidget(
        _wrap(container: container, settings: const AppSettings()),
      );
      await tester.pump();

      final tile = tester.widget<SwitchListTile>(
        find.byKey(const Key('settings.allowProjectDefinedTooling')),
      );
      expect(tile.value, isFalse);
    });

    testWidgets('reflects a settings value of true', (tester) async {
      final container = await makeContainer();
      await tester.pumpWidget(
        _wrap(
          container: container,
          settings: const AppSettings(allowProjectDefinedTooling: true),
        ),
      );
      await tester.pump();

      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('settings.allowProjectDefinedTooling')),
            )
            .value,
        isTrue,
      );
    });

    testWidgets('toggling it persists the decision', (tester) async {
      final container = await makeContainer();
      await tester.pumpWidget(
        _wrap(container: container, settings: const AppSettings()),
      );
      await tester.pump();

      await tester.tap(
        find.byKey(const Key('settings.allowProjectDefinedTooling')),
      );
      await tester.pump();
      await container.read(appSettingsProvider.future);

      expect(
        container.read(appSettingsProvider).value!.allowProjectDefinedTooling,
        isTrue,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('simcrux.allowProjectDefinedTooling'), isTrue);
    });
  });

  testWidgets('locale sweep renders without exceptions', (tester) async {
    for (final locale in const [
      Locale('en'),
      Locale('zh', 'CN'),
      Locale('zh'),
      Locale('ja'),
      Locale('ko'),
    ]) {
      final container = await makeContainer();
      await tester.pumpWidget(
        _wrap(
          container: container,
          settings: const AppSettings(),
          locale: locale,
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull, reason: '$locale');
    }
  });
}
