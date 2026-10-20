// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:crux_ide_layout/crux_ide_layout.dart' show CruxHelpLink;
import 'package:crux_settings_ui/crux_settings_ui.dart' show CruxFormRow;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/core/help_urls.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/settings/widgets/settings_remote_control_section.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

import '../../../support/cxp_test_overrides.dart';

Widget _wrap({
  required ProviderContainer container,
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
      home: const Scaffold(body: SettingsRemoteControlSection()),
    ),
  );
}

ProviderContainer _container([List<Override> overrides = const <Override>[]]) {
  final container = ProviderContainer(
    overrides: [...simcruxCxpTestOverrides(), ...overrides],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('renders the shared controls with the current settings', (
    tester,
  ) async {
    final container = _container();
    await tester.pumpWidget(_wrap(container: container));
    await tester.pump();

    // Three switches: the CXP enable toggle, the request-attention
    // toggle, and the broadcast-selection toggle.
    expect(find.byType(Switch), findsNWidgets(3));
    expect(find.text('Enable CXP server'), findsOneWidget);
    expect(find.text('Request attention on cross-probe'), findsOneWidget);
    expect(find.text('Broadcast selection automatically'), findsOneWidget);
    expect(find.text('CXP port'), findsOneWidget);
    expect(find.text('54325'), findsOneWidget);
    // The status line is always present.
    expect(find.text('CXP status'), findsOneWidget);
  });

  testWidgets('the CXP controls render in the canonical order', (tester) async {
    final container = _container();
    await tester.pumpWidget(_wrap(container: container));
    await tester.pump();

    final enableY = tester.getTopLeft(find.text('Enable CXP server')).dy;
    final portY = tester.getTopLeft(find.text('CXP port')).dy;
    final attentionY = tester
        .getTopLeft(find.text('Request attention on cross-probe'))
        .dy;
    final broadcastY = tester
        .getTopLeft(find.text('Broadcast selection automatically'))
        .dy;
    final statusY = tester.getTopLeft(find.text('CXP status')).dy;

    expect(enableY, lessThan(portY));
    expect(portY, lessThan(attentionY));
    expect(attentionY, lessThan(broadcastY));
    expect(broadcastY, lessThan(statusY));
  });

  testWidgets('the help link beside the section opens the integrations page', (
    tester,
  ) async {
    final container = _container();
    await tester.pumpWidget(_wrap(container: container));
    await tester.pump();

    final link = tester.widget<CruxHelpLink>(find.byType(CruxHelpLink));
    expect(link.url, HelpUrls.integrations);
  });

  testWidgets('status line reads Running on port when the server is up', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: simcruxCxpTestOverrides(running: true),
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(_wrap(container: container));
    await tester.pump();

    expect(find.textContaining('Running on port 54325'), findsOneWidget);
    expect(find.textContaining('0 peers connected'), findsOneWidget);
  });

  testWidgets('status line reads Stopped when the server is down', (
    tester,
  ) async {
    final container = _container();
    await tester.pumpWidget(_wrap(container: container));
    await tester.pump();

    expect(find.textContaining('Stopped'), findsOneWidget);
  });

  testWidgets('toggling the switch updates and saves the setting', (
    tester,
  ) async {
    final container = _container();
    await tester.pumpWidget(_wrap(container: container));
    await tester.pump();

    final switchFinder = find.descendant(
      of: find.widgetWithText(CruxFormRow, 'Enable CXP server'),
      matching: find.byType(Switch),
    );
    expect((tester.widget(switchFinder) as Switch).value, isTrue);

    await tester.tap(switchFinder);
    await tester.pump();

    expect(container.read(cruxCxpSettingsProvider).enabled, isFalse);
    // Saved at once, under the key SimCrux has always used.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('simcrux.cxpServerEnabled'), isFalse);
  });

  testWidgets('toggling the attention switch updates and saves the setting', (
    tester,
  ) async {
    final container = _container();
    await tester.pumpWidget(_wrap(container: container));
    await tester.pump();

    final attentionSwitch = find.descendant(
      of: find.widgetWithText(CruxFormRow, 'Request attention on cross-probe'),
      matching: find.byType(Switch),
    );
    expect((tester.widget(attentionSwitch) as Switch).value, isTrue);

    await tester.tap(attentionSwitch);
    await tester.pump();

    expect(container.read(cruxCxpSettingsProvider).requestAttention, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('simcrux.requestAttentionOnCrossProbe'), isFalse);
  });

  testWidgets('toggling the broadcast switch updates and saves the setting', (
    tester,
  ) async {
    final container = _container();
    await tester.pumpWidget(_wrap(container: container));
    await tester.pump();

    final broadcastSwitch = find.descendant(
      of: find.widgetWithText(
        CruxFormRow,
        'Broadcast selection automatically',
      ),
      matching: find.byType(Switch),
    );
    expect((tester.widget(broadcastSwitch) as Switch).value, isTrue);

    await tester.tap(broadcastSwitch);
    await tester.pump();

    expect(container.read(cruxCxpSettingsProvider).broadcastSelection, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('simcrux.broadcastSelectionOnCrossProbe'), isFalse);
  });

  testWidgets('entering a valid port updates and saves the setting', (
    tester,
  ) async {
    final container = _container();
    await tester.pumpWidget(_wrap(container: container));
    await tester.pump();

    await tester.enterText(find.byType(TextField), '60000');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(container.read(cruxCxpSettingsProvider).port, 60000);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('simcrux.cxpServerPort'), 60000);
  });

  testWidgets('entering an invalid port shows the error and does not update', (
    tester,
  ) async {
    final container = _container();
    await tester.pumpWidget(_wrap(container: container));
    await tester.pump();

    await tester.enterText(find.byType(TextField), '99999');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(find.text('Enter a port between 1 and 65535.'), findsOneWidget);
    expect(container.read(cruxCxpSettingsProvider).port, 54325);
  });

  testWidgets(
    'an unrelated settings save leaves the CXP settings as the user set them',
    (tester) async {
      final container = _container();
      await tester.pumpWidget(_wrap(container: container));
      await tester.pump();

      await tester.tap(
        find.descendant(
          of: find.widgetWithText(CruxFormRow, 'Enable CXP server'),
          matching: find.byType(Switch),
        ),
      );
      await tester.pump();

      // Opening a project saves the whole settings object. The app settings
      // codec must not write the four CXP keys back with its own defaults.
      await container.read(appSettingsProvider.future);
      await container.read(appSettingsProvider.notifier).setRecentProjects(
        const <String>['/proj/a/simcrux.yaml'],
      );

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('simcrux.cxpServerEnabled'), isFalse);
    },
  );

  group('locale sweep', () {
    for (final locale in const <Locale>[
      Locale('zh', 'CN'),
      Locale('zh'),
      Locale('ja'),
      Locale('ko'),
    ]) {
      testWidgets('renders in ${locale.toLanguageTag()} without exception', (
        tester,
      ) async {
        final container = ProviderContainer(
          overrides: simcruxCxpTestOverrides(running: true),
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(_wrap(container: container, locale: locale));
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  });
}
