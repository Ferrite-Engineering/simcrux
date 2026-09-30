// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// integration_test/workspace/split_pane_test.dart
//
// Split-pane — tab between panes. Exercises the `splitPaneRight` +
// `moveTabToPane` mutation contract against the live workspace: splitting
// creates a second pane, moving a tab reassigns its `paneId`, and emptying a
// pane collapses the workspace back to a single pane. Ported from NetCrux's
// `integration_test/workspace/split_pane_test.dart`.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';

import '../helpers/app_driver.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  suppressPlatformSemanticsLeak();

  testWidgets(
    'split right then move a tab between panes',
    (tester) async {
      await bootSimcrux(tester);
      final root = rootContainer(tester);
      final notifier = root.read(workspaceProvider.notifier);

      final t1 = await notifier.openTab(
        displayName: 'alpha',
        payload: SimcruxTabPayload(configPath: '/tmp/alpha.simcrux.yaml'),
      );
      final t2 = await notifier.openTab(
        displayName: 'beta',
        payload: SimcruxTabPayload(configPath: '/tmp/beta.simcrux.yaml'),
      );
      await pumpUntil(tester, () => tabCount(tester) == 2);
      expect(tabCount(tester), 2);

      // Split a new pane to the right.
      final rightPane = await notifier.splitPaneRight();
      await tester.pump();
      var ws = root.read(workspaceProvider).value!;
      expect(ws.panes, hasLength(2), reason: 'split creates a second pane');

      // Move both tabs into the right pane; the left pane then has none.
      await notifier.moveTabToPane(t1, rightPane);
      await notifier.moveTabToPane(t2, rightPane);
      await tester.pump();
      ws = root.read(workspaceProvider).value!;
      expect(
        ws.tabs.where((t) => t.paneId == rightPane),
        hasLength(2),
        reason: 'both tabs now live in the right pane',
      );

      // A pane emptied of all tabs collapses — the workspace returns to a
      // single pane (the surviving populated one).
      expect(
        ws.panes,
        hasLength(1),
        reason: 'the now-empty left pane collapses back to single-pane',
      );

      expect(tester.takeException(), isNull);
    },
  );
}
