// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_settings/crux_settings.dart';
import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/diagnostics/widgets/tab_diagnostics_drawer.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/container_managers.dart';
import 'package:simcrux/features/workspace/providers/simcrux_pane_overrides.dart';
import 'package:simcrux/features/workspace/providers/simcrux_tab_overrides.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/services/simcrux_workspace_codec.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/settings/simcrux_settings_codec.dart';

import '../../../support/answered_telemetry.dart';

RegressionConfig _config() => RegressionConfig(
  projectFilePath: '/proj/simcrux.yaml',
  schemaVersion: '1',
  suites: [
    Suite(
      name: 'unit',
      tests: [
        TestSpec(
          id: 'unit/alu',
          name: 'alu',
          suiteName: 'unit',
          simulatorId: 'icarus',
          top: 'alu_tb',
        ),
        TestSpec(
          id: 'unit/regfile',
          name: 'regfile',
          suiteName: 'unit',
          simulatorId: 'icarus',
          top: 'regfile_tb',
        ),
      ],
    ),
  ],
  simulatorBinaries: const <String, SimulatorBinaryConfig>{},
);

Widget _wrap({
  List<Override> overrides = const [],
  Locale locale = const Locale('en'),
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      locale: locale,
      localizationsDelegates: const [
        L10N.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: L10N.supportedLocales,
      home: const Scaffold(body: TabDiagnosticsDrawer()),
    ),
  );
}

void main() {
  group('TabDiagnosticsDrawer', () {
    testWidgets('renders the three sections and registered drivers', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap());
      await tester.pump();

      final l10n = L10N.of(tester.element(find.byType(Scaffold)));
      expect(find.text(l10n.diagnosticsTabConfigInfo), findsOneWidget);
      expect(find.text(l10n.diagnosticsTabSimulatorBackend), findsOneWidget);
      expect(find.text(l10n.diagnosticsTabSchedulerState), findsOneWidget);
      expect(
        find.text(l10n.diagnosticsActionCopyTabReport),
        findsOneWidget,
      );
      // The built-in driver registry rows.
      for (final id in const ['icarus', 'verilator', 'ghdl', 'cocotb']) {
        expect(find.text(id), findsOneWidget, reason: id);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders the localized no-config-loaded placeholder', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap());
      await tester.pump();

      final l10n = L10N.of(tester.element(find.byType(Scaffold)));
      expect(find.text(l10n.diagnosticsTabNoConfigLoaded), findsOneWidget);
    });

    testWidgets('renders config metadata when a config is active', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          overrides: [
            activeConfigProvider.overrideWith(_StubActiveConfig.new),
          ],
        ),
      );
      await tester.pump();

      // Path, suite count and test count rows from the active config.
      expect(find.textContaining('/proj/simcrux.yaml'), findsOneWidget);
      expect(find.textContaining('1'), findsWidgets); // suites
      expect(find.textContaining('2'), findsWidgets); // tests
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'open() mounts a NON-MODAL overlay drawer scoped to the active tab '
      'and Escape closes it (WaveCrux Tab Diagnostics parity)',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1200, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final prefs = await SharedPreferences.getInstance();
        final workspaceDir = Directory.systemTemp.createTempSync(
          'simcrux_tdd_open_test',
        );
        addTearDown(() {
          if (workspaceDir.existsSync()) {
            workspaceDir.deleteSync(recursive: true);
          }
        });

        // Two-phase container wiring mirroring bootstrap() (the same
        // harness shape as workspace_screen_test.dart).
        late final WorkspaceContainerManagers managers;
        final root = ProviderContainer(
          retry: (_, _) => null,
          overrides: [
            ...answeredTelemetryOverrides(),
            settingsServiceProvider.overrideWithValue(
              SettingsService<AppSettings>(
                const SimcruxSettingsCodec(),
                prefsOverride: prefs,
              ),
            ),
            simcruxWorkspaceServiceProvider.overrideWithValue(
              crux.WorkspaceService<SimcruxTabPayload>(
                codec: const SimcruxWorkspaceCodec(),
                directoryFactory: () async => workspaceDir,
              ),
            ),
            workspaceContainerManagersProvider.overrideWith((_) => managers),
          ],
        );
        addTearDown(root.dispose);
        managers = WorkspaceContainerManagers(
          tabs: crux.TabContainerManager(
            rootContainer: root,
            overridesFactory: root.read(simcruxTabOverridesFactoryProvider),
          ),
          panes: crux.PaneContainerManager(
            rootContainer: root,
            overridesFactory: simcruxPaneOverrides,
          ),
        );
        addTearDown(managers.dispose);
        final scoped = ProviderContainer(
          parent: root,
          overrides: [
            workspaceContainerManagersProvider.overrideWithValue(managers),
          ],
        );
        addTearDown(scoped.dispose);
        await scoped.read(workspaceProvider.future);
        final notifier = scoped.read(workspaceProvider.notifier);
        await tester.runAsync(
          () => notifier.openTab(
            displayName: 'demo',
            payload: SimcruxTabPayload(configPath: ''),
          ),
        );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: scoped,
            child: MaterialApp(
              localizationsDelegates: const [
                L10N.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: L10N.supportedLocales,
              home: Builder(
                builder: (context) => Scaffold(
                  body: Center(
                    child: ElevatedButton(
                      onPressed: () => TabDiagnosticsDrawer.open(context),
                      child: const Text('open drawer'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        // The home route's own ModalBarrier is always present; opening the
        // drawer must not add another (a modal dialog route would).
        final barriersBefore = find.byType(ModalBarrier).evaluate().length;

        await tester.tap(find.text('open drawer'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        final l10n = L10N.of(tester.element(find.byType(Scaffold)));
        expect(find.byType(TabDiagnosticsDrawer), findsOneWidget);
        expect(find.text(l10n.diagnosticsTabConfigInfo), findsOneWidget);
        // Non-modal: no barrier was added — the chrome outside the drawer
        // stays hit-testable (the WaveCrux OverlayEntry contract).
        expect(
          find.byType(ModalBarrier).evaluate().length,
          barriersBefore,
        );

        // Escape closes the drawer (host-level DismissIntent binding).
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(TabDiagnosticsDrawer), findsNothing);

        // Drain the debounced workspace auto-save so no timer leaks.
        await tester.runAsync(notifier.flushPendingSave);
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('locale sweep renders without exceptions', (tester) async {
      for (final locale in const [
        Locale('en'),
        Locale('zh', 'CN'),
        Locale('zh'),
        Locale('ja'),
        Locale('ko'),
      ]) {
        await tester.pumpWidget(
          _wrap(
            overrides: [
              activeConfigProvider.overrideWith(_StubActiveConfig.new),
            ],
            locale: locale,
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull, reason: '$locale');
      }
    });
  });
}

class _StubActiveConfig extends ActiveConfigNotifier {
  @override
  RegressionConfig? build() => _config();
}
