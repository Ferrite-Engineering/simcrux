// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_settings/crux_settings.dart';
import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/app.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/features/issue_reporter/providers/issue_reporter_overrides.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/update/providers/update_overrides.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/container_managers.dart';
import 'package:simcrux/features/workspace/providers/simcrux_pane_overrides.dart';
import 'package:simcrux/features/workspace/providers/simcrux_tab_overrides.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/services/simcrux_workspace_codec.dart';
import 'package:simcrux/services/settings/simcrux_settings_codec.dart';

import 'support/answered_telemetry.dart';

/// Verifies `SimcruxApp` wires the high-contrast accessibility themes into
/// `MaterialApp` (parity with WaveCrux). The harness mirrors the two-phase
/// container wiring from `bootstrap()` so `SimcruxApp` can build its router
/// and root chrome exactly as it does at runtime.
Future<({ProviderContainer root, ProviderContainer scoped})> _bootScoped({
  required Directory workspaceDir,
  required SharedPreferences prefs,
}) async {
  final root = ProviderContainer(
    overrides: [
      ...answeredTelemetryOverrides(),
      // Mirror bootstrap()'s beta-infrastructure wiring: `SimcruxApp`'s builder mounts
      // the UpdateBanner, whose provider graph reaches
      // `cruxUpdateConfigProvider` — a seam with no default binding by
      // design, so an unwired product fails loudly rather than silently
      // never checking for updates.
      ...simcruxUpdateOverrides,
      ...simcruxIssueReporterOverrides,
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
    ],
  );
  addTearDown(root.dispose);
  final managers = WorkspaceContainerManagers(
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
  return (root: root, scoped: scoped);
}

void main() {
  late Directory workspaceDir;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
    workspaceDir = Directory.systemTemp.createTempSync('app_hc_theme_test');
  });

  tearDown(() {
    if (workspaceDir.existsSync()) {
      workspaceDir.deleteSync(recursive: true);
    }
  });

  testWidgets('SimcruxApp wires high-contrast light and dark themes', (
    tester,
  ) async {
    final containers = await _bootScoped(
      workspaceDir: workspaceDir,
      prefs: prefs,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: containers.scoped,
        child: const SimcruxApp(),
      ),
    );
    await tester.pumpAndSettle();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(
      app.highContrastTheme,
      isNotNull,
      reason: 'highContrastTheme must be wired for accessibility parity',
    );
    expect(app.highContrastDarkTheme, isNotNull);
    expect(app.highContrastTheme!.brightness, Brightness.light);
    expect(app.highContrastDarkTheme!.brightness, Brightness.dark);

    // Dispose inside the test body, not only via addTearDown: mounting the
    // real `SimcruxApp` materializes `updateStatusProvider`, which owns the
    // 24 h periodic auto-check `Timer` (cancelled on provider dispose).
    // `_verifyInvariants`' pending-timer check runs *before* tearDown
    // callbacks, so the container has to go first. Both disposals are
    // idempotent, so the addTearDown pair still runs harmlessly. The root
    // container is the one that holds the element (the provider is not
    // overridden in the scoped child), so disposing the child alone is not
    // enough.
    containers.root.dispose();
  });
}
