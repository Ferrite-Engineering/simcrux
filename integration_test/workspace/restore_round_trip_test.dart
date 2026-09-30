// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// integration_test/workspace/restore_round_trip_test.dart
//
// Workspace auto-save + restore round-trip. `runApp` runs once per process, so
// "quit and relaunch" is approximated by driving the live workspace, flushing
// the debounced auto-save, and re-reading the persisted `workspace.json`
// through a fresh `WorkspaceService` — the same pattern the NetCrux/WaveCrux
// suites use.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';

import '../helpers/app_driver.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  suppressPlatformSemanticsLeak();

  testWidgets(
    'two opened tabs auto-persist and re-read identically',
    (tester) async {
      await bootSimcrux(tester);
      final root = rootContainer(tester);
      final notifier = root.read(workspaceProvider.notifier);

      await notifier.openTab(
        displayName: 'alpha',
        payload: SimcruxTabPayload(configPath: '/tmp/alpha.simcrux.yaml'),
      );
      await notifier.openTab(
        displayName: 'beta',
        payload: SimcruxTabPayload(configPath: '/tmp/beta.simcrux.yaml'),
      );
      await pumpUntil(tester, () => tabCount(tester) == 2);
      expect(tabCount(tester), 2);

      await notifier.flushPendingSave();

      final reloaded = await freshWorkspaceLoad();
      expect(reloaded.tabs, hasLength(2));
      expect(
        reloaded.tabs.map((t) => t.displayName).toSet(),
        containsAll(<String>['alpha', 'beta']),
      );
      expect(
        reloaded.tabs.map((t) => t.payload.configPath).toSet(),
        containsAll(<String>[
          '/tmp/alpha.simcrux.yaml',
          '/tmp/beta.simcrux.yaml',
        ]),
      );

      expect(tester.takeException(), isNull);
    },
  );
}
