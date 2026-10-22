// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/enums/riscv_host_platform.dart';
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/settings/widgets/settings_implementation_flow_section.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/flow/flow_toolchain_probe.dart';

/// Settings > Engines > Implementation flow: the launcher, the paths and
/// Check Flow Tools, each writing the user's own Settings (never gated).
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<ProviderContainer> pump(WidgetTester tester, {Locale? locale}) async {
    final container = ProviderContainer(
      overrides: [
        flowToolchainProbeProvider.overrideWithValue(
          FlowToolchainProbe(
            platform: RiscvHostPlatform.linux,
            environment: const <String, String>{},
            runner: (binary, args) async => binary.contains('nextpnr')
                ? (exitCode: 0, lines: <String>['nextpnr 0.9'])
                : null,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final settings = await container.read(appSettingsProvider.future);
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
          home: Scaffold(
            body: SingleChildScrollView(
              child: FlowToolSettingsRows(settings: settings),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return container;
  }

  testWidgets('every locale names every row, without overflow', (
    tester,
  ) async {
    for (final locale in L10N.supportedLocales) {
      await pump(tester, locale: locale);
      final l10n = L10N.of(tester.element(find.byType(Scaffold)));
      for (final label in [
        l10n.settingsFlowLauncherLabel,
        l10n.settingsFlowPdkRootLabel,
        l10n.settingsFlowKlayoutLabel,
        l10n.settingsFlowOpenroadLabel,
        l10n.settingsFlowFusesocLabel,
        l10n.settingsFlowDockerImageLabel,
      ]) {
        expect(label.trim(), isNotEmpty, reason: '$locale');
      }
      expect(tester.takeException(), isNull, reason: '$locale');
    }
  });

  testWidgets('choosing Docker saves the launcher', (tester) async {
    final container = await pump(tester);
    final l10n = L10N.of(tester.element(find.byType(Scaffold)));
    await tester.tap(find.text(l10n.settingsFlowLauncherDocker));
    await tester.pump();
    expect(
      container.read(appSettingsProvider).value!.flowTools.launcher,
      FlowLauncher.docker,
    );
  });

  testWidgets('a submitted PDK root is saved', (tester) async {
    final container = await pump(tester);
    await tester.enterText(find.byKey(const ValueKey('flowPdkRoot')), '/pdks');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(
      container.read(appSettingsProvider).value!.flowTools.pdkRoot,
      '/pdks',
    );
  });

  testWidgets('Check flow tools lists what answered and guides the rest', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        flowToolchainProbeProvider.overrideWithValue(
          FlowToolchainProbe(
            platform: RiscvHostPlatform.linux,
            environment: const <String, String>{},
            runner: (binary, args) async => binary.contains('nextpnr')
                ? (exitCode: 0, lines: <String>['nextpnr 0.9'])
                : null,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final settings = await container.read(appSettingsProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: const [
            L10N.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: L10N.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: FlowToolchainCheck(settings: settings),
            ),
          ),
        ),
      ),
    );
    final l10n = L10N.of(tester.element(find.byType(Scaffold)));
    await tester.tap(find.byKey(const ValueKey('flowToolsCheck')));
    await tester.pumpAndSettle();
    expect(find.text('nextpnr-ice40: nextpnr 0.9'), findsOneWidget);
    expect(find.text('librelane: not found'), findsOneWidget);
    expect(find.text(l10n.settingsFlowToolsNoPdk), findsOneWidget);
    expect(find.text(l10n.settingsFlowToolsGuidance), findsOneWidget);
  });
}
