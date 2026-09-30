// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_settings/crux_settings.dart';
import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/container_managers.dart';
import 'package:simcrux/features/workspace/providers/simcrux_pane_overrides.dart';
import 'package:simcrux/features/workspace/providers/simcrux_tab_overrides.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/screens/workspace_screen.dart';
import 'package:simcrux/features/workspace/services/simcrux_workspace_codec.dart';
import 'package:simcrux/features/workspace/widgets/empty_canvas_content.dart';
import 'package:simcrux/features/workspace/widgets/regression_tab_content.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/settings/simcrux_settings_codec.dart';

import '../../../support/answered_telemetry.dart';

/// Test harness mirroring the two-phase container wiring from
/// `bootstrap()` in `lib/app.dart`: a root container carrying the
/// service overrides, per-tab / per-pane managers parented to it, and
/// a scoped child container exposing the managers.
class _Harness {
  _Harness._(this.scoped);

  final ProviderContainer scoped;

  static Future<_Harness> create({
    required Directory workspaceDir,
    required SharedPreferences prefs,
  }) async {
    // The managers provider must resolve from the ROOT container too (its
    // default throws, and per-tab containers parent to root, not to the
    // scoped child below). A per-tab read of the throwing default puts the
    // element in error state and Riverpod 3 schedules retry timers, which
    // trip the pending-timer teardown check. The `late` indirection breaks
    // the root->managers->root construction cycle: the override body only
    // runs on first read, well after assignment.
    late final WorkspaceContainerManagers managers;
    final root = ProviderContainer(
      // Riverpod 3 auto-retries failing providers on a 200 ms backoff
      // timer. In a fake-async widget test that timer is still pending at
      // teardown and trips the pending-timer invariant. Retry is inherited
      // by child containers (scoped + per-tab), so disabling it here makes
      // provider failures surface once, deterministically.
      retry: (_, _) => null,
      overrides: [
        ...answeredTelemetryOverrides(),
        settingsServiceProvider.overrideWithValue(
          SettingsService<AppSettings>(
            const SimcruxSettingsCodec(),
            prefsOverride: prefs,
          ),
        ),
        // Keep the auto-managed workspace.json inside the test's temp
        // directory instead of the platform app-support location.
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
    // Hydrate the workspace before the first frame, as bootstrap() does,
    // so PaneHost sees a resolved AsyncValue instead of AsyncLoading.
    await scoped.read(workspaceProvider.future);
    return _Harness._(scoped);
  }

  Widget wrap({Locale locale = const Locale('en')}) {
    return UncontrolledProviderScope(
      container: scoped,
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: const [
          L10N.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: L10N.supportedLocales,
        home: const WorkspaceScreen(),
      ),
    );
  }
}

void main() {
  late Directory workspaceDir;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
    workspaceDir = Directory.systemTemp.createTempSync(
      'workspace_screen_test',
    );
  });

  tearDown(() {
    if (workspaceDir.existsSync()) {
      workspaceDir.deleteSync(recursive: true);
    }
  });

  group('WorkspaceScreen', () {
    testWidgets('renders the empty-canvas content when no tabs are open', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final harness = await _Harness.create(
        workspaceDir: workspaceDir,
        prefs: prefs,
      );
      await tester.pumpWidget(harness.wrap());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(crux.PaneHost<SimcruxTabPayload>), findsOneWidget);
      expect(find.byType(EmptyCanvasContent), findsOneWidget);
      final l10n = L10N.of(tester.element(find.byType(Scaffold)));
      expect(find.text(l10n.emptyCanvasTitle), findsOneWidget);
      expect(find.text(l10n.emptyCanvasOpenConfig), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('opening a tab swaps the empty canvas for tab content', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final harness = await _Harness.create(
        workspaceDir: workspaceDir,
        prefs: prefs,
      );
      await tester.pumpWidget(harness.wrap());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final notifier = harness.scoped.read(workspaceProvider.notifier);
      // openTab's save path does real file I/O, which never completes
      // inside the fake-async test zone — run it on the real event loop.
      await tester.runAsync(
        () => notifier.openTab(
          displayName: 'new tab',
          payload: SimcruxTabPayload(configPath: ''),
        ),
      );
      // Don't pumpAndSettle — the per-tab content would try to spin up
      // the watcher / persistence layers. Two bounded frames are enough
      // for the tab scaffolding to appear.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(EmptyCanvasContent), findsNothing);
      expect(find.byType(RegressionTabContent), findsOneWidget);
      expect(find.text('new tab'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Flush the debounced workspace.json auto-save (real file write,
      // hence runAsync) so no timer stays pending at teardown.
      await tester.runAsync(notifier.flushPendingSave);
      await tester.pump();
      // The app-level toolbar watches the action context, whose active-tab
      // flags mirror re-subscribes when a tab opens and asks Riverpod for a
      // refresh. That schedules a zero-duration scheduler timer; drain it
      // rather than leaving it pending at teardown.
      await tester.pump(const Duration(milliseconds: 100));
    });

    testWidgets('locale sweep renders without exceptions', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final harness = await _Harness.create(
        workspaceDir: workspaceDir,
        prefs: prefs,
      );
      for (final locale in const [
        Locale('en'),
        Locale('zh', 'CN'),
        Locale('zh'),
        Locale('ja'),
        Locale('ko'),
      ]) {
        await tester.pumpWidget(harness.wrap(locale: locale));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull, reason: '$locale');
      }
    });
  });
}
