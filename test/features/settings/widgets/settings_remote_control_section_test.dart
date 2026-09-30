// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'package:crux_cxp/crux_cxp.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/features/remote/providers/cxp_discovery_provider.dart';
import 'package:simcrux/features/remote/providers/cxp_server_provider.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/settings/widgets/settings_remote_control_section.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/remote/cxp/simcrux_cxp_server.dart';

// A CXP server notifier that resolves to null without touching the network —
// the section reads `cxpServerProvider.value` for its running state, so a
// disabled server keeps the test hermetic (no real socket bind).
class _DisabledCxpServerNotifier extends CxpServerNotifier {
  @override
  Future<SimCruxCxpServer?> build() async => null;
}

// A CXP server notifier that resolves to a (non-started) fake, so the section
// reads it as "running" for the status line without binding a real port.
class _RunningCxpServerNotifier extends CxpServerNotifier {
  _RunningCxpServerNotifier(this._fake);
  final SimCruxCxpServer _fake;

  @override
  Future<SimCruxCxpServer?> build() async => _fake;
}

class _StaticPeersNotifier extends CxpPeersNotifier {
  _StaticPeersNotifier(this._peers);
  final List<CxpPeerManifest> _peers;

  @override
  List<CxpPeerManifest> build() => _peers;
}

List<Override> _cxpOverrides({
  required bool running,
  List<CxpPeerManifest> peers = const <CxpPeerManifest>[],
}) {
  return <Override>[
    cxpServerProvider.overrideWith(
      running
          ? () => _RunningCxpServerNotifier(
              SimCruxCxpServer(
                selfIdentity: buildSimcruxPeerIdentity(processId: 1),
              ),
            )
          : _DisabledCxpServerNotifier.new,
    ),
    cxpPeersProvider.overrideWith(() => _StaticPeersNotifier(peers)),
  ];
}

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
        body: SettingsRemoteControlSection(settings: settings),
      ),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('renders enable switch + port field with current settings', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: _cxpOverrides(running: false),
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);

    const settings = AppSettings();
    await tester.pumpWidget(_wrap(container: container, settings: settings));
    await tester.pump();

    // Three switches: the CXP enable toggle, the request-attention
    // toggle, and the broadcast-selection toggle.
    expect(find.byType(Switch), findsNWidgets(3));
    expect(find.text('Enable CXP server'), findsOneWidget);
    expect(find.text('Request attention on cross-probe'), findsOneWidget);
    expect(find.text('Broadcast selection automatically'), findsOneWidget);
    expect(find.text('CXP port'), findsOneWidget);
    expect(find.text('54325'), findsOneWidget);
    // The CXP Status line is always present.
    expect(find.text('CXP Status'), findsOneWidget);
  });

  testWidgets(
    'the five CXP controls render in the canonical order '
    '(Enable → Port → Request-attention → Broadcast-selection → Status)',
    (tester) async {
      final container = ProviderContainer(
        overrides: _cxpOverrides(running: true),
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);

      const settings = AppSettings();
      await tester.pumpWidget(_wrap(container: container, settings: settings));
      await tester.pump();

      final enableY = tester.getTopLeft(find.text('Enable CXP server')).dy;
      final portY = tester.getTopLeft(find.text('CXP port')).dy;
      final attentionY = tester
          .getTopLeft(find.text('Request attention on cross-probe'))
          .dy;
      final broadcastY = tester
          .getTopLeft(find.text('Broadcast selection automatically'))
          .dy;
      final statusY = tester.getTopLeft(find.text('CXP Status')).dy;

      expect(enableY, lessThan(portY));
      expect(portY, lessThan(attentionY));
      expect(attentionY, lessThan(broadcastY));
      expect(broadcastY, lessThan(statusY));
    },
  );

  testWidgets('status line reads Running on port when the server is up', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: _cxpOverrides(running: true),
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);

    const settings = AppSettings();
    await tester.pumpWidget(_wrap(container: container, settings: settings));
    await tester.pump();

    expect(find.text('Running on port 54325'), findsOneWidget);
    expect(find.text('0 peer(s) connected'), findsOneWidget);
  });

  testWidgets('status line reads Stopped when the server is down', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: _cxpOverrides(running: false),
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);

    const settings = AppSettings();
    await tester.pumpWidget(_wrap(container: container, settings: settings));
    await tester.pump();

    // "Stopped" shows both as the trailing status and the subtitle.
    expect(find.text('Stopped'), findsWidgets);
  });

  testWidgets('toggling the switch updates the setting', (tester) async {
    final container = ProviderContainer(
      overrides: _cxpOverrides(running: false),
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);

    const settings = AppSettings();
    await tester.pumpWidget(_wrap(container: container, settings: settings));
    await tester.pump();

    final switchFinder = find.descendant(
      of: find.widgetWithText(SwitchListTile, 'Enable CXP server'),
      matching: find.byType(Switch),
    );
    expect(
      (tester.widget(switchFinder) as Switch).value,
      isTrue,
    );

    await tester.tap(switchFinder);
    await tester.pump();
    await container.read(appSettingsProvider.future);

    expect(
      container.read(appSettingsProvider).value!.cxpServerEnabled,
      isFalse,
    );
  });

  testWidgets('toggling the attention switch updates the setting', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: _cxpOverrides(running: false),
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);

    const settings = AppSettings();
    await tester.pumpWidget(_wrap(container: container, settings: settings));
    await tester.pump();

    final attentionSwitch = find.descendant(
      of: find.widgetWithText(
        SwitchListTile,
        'Request attention on cross-probe',
      ),
      matching: find.byType(Switch),
    );
    expect((tester.widget(attentionSwitch) as Switch).value, isTrue);

    await tester.tap(attentionSwitch);
    await tester.pump();
    await container.read(appSettingsProvider.future);

    expect(
      container.read(appSettingsProvider).value!.requestAttentionOnCrossProbe,
      isFalse,
    );
  });

  testWidgets('toggling the broadcast switch updates the setting', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: _cxpOverrides(running: false),
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);

    const settings = AppSettings();
    await tester.pumpWidget(_wrap(container: container, settings: settings));
    await tester.pump();

    final broadcastSwitch = find.descendant(
      of: find.widgetWithText(
        SwitchListTile,
        'Broadcast selection automatically',
      ),
      matching: find.byType(Switch),
    );
    expect((tester.widget(broadcastSwitch) as Switch).value, isTrue);

    await tester.tap(broadcastSwitch);
    await tester.pump();
    await container.read(appSettingsProvider.future);

    expect(
      container.read(appSettingsProvider).value!.broadcastSelectionOnCrossProbe,
      isFalse,
    );
  });

  testWidgets('entering a valid port updates the setting', (tester) async {
    final container = ProviderContainer(
      overrides: _cxpOverrides(running: false),
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);

    const settings = AppSettings();
    await tester.pumpWidget(_wrap(container: container, settings: settings));
    await tester.pump();

    final portField = find.byType(TextField);
    await tester.enterText(portField, '60000');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await container.read(appSettingsProvider.future);

    expect(
      container.read(appSettingsProvider).value!.cxpServerPort,
      60000,
    );
  });

  testWidgets('entering an invalid port shows the error and does not update', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: _cxpOverrides(running: false),
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);

    const settings = AppSettings();
    await tester.pumpWidget(_wrap(container: container, settings: settings));
    await tester.pump();

    await tester.enterText(find.byType(TextField), '99999');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(find.text('Enter a port between 1 and 65535.'), findsOneWidget);
    expect(
      container.read(appSettingsProvider).value!.cxpServerPort,
      54325, // unchanged
    );
  });

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
          overrides: _cxpOverrides(running: true),
        );
        addTearDown(container.dispose);
        await container.read(appSettingsProvider.future);

        const settings = AppSettings();
        await tester.pumpWidget(
          _wrap(container: container, settings: settings, locale: locale),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  });
}
