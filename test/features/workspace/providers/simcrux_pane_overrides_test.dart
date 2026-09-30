// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/workspace/providers/pane_render_stats_provider.dart';
import 'package:simcrux/features/workspace/providers/simcrux_pane_overrides.dart';

void main() {
  group('simcruxPaneOverrides', () {
    test('isolates paneRenderStats samples between two panes', () {
      final root = ProviderContainer();
      addTearDown(root.dispose);
      final paneA = ProviderContainer(
        parent: root,
        overrides: simcruxPaneOverrides(crux.PaneId.generate()),
      );
      addTearDown(paneA.dispose);
      final paneB = ProviderContainer(
        parent: root,
        overrides: simcruxPaneOverrides(crux.PaneId.generate()),
      );
      addTearDown(paneB.dispose);

      paneA
          .read(paneRenderStatsProvider.notifier)
          .recordPaint(paintMs: 12, when: DateTime(2026));

      expect(paneA.read(paneRenderStatsProvider).lastPaintMs, 12);
      expect(paneA.read(paneRenderStatsProvider).sampleCount, 1);
      expect(paneB.read(paneRenderStatsProvider), PaneRenderStats.empty);
    });
  });

  group('WorkspaceContainerManagers (integration)', () {
    test('crux.TabContainerManager + simcruxTabOverrides + '
        'crux.PaneContainerManager + simcruxPaneOverrides round-trip', () {
      final root = ProviderContainer();
      addTearDown(root.dispose);
      final tabs = crux.TabContainerManager(rootContainer: root);
      addTearDown(tabs.dispose);
      final panes = crux.PaneContainerManager(
        rootContainer: root,
        overridesFactory: simcruxPaneOverrides,
      );
      addTearDown(panes.dispose);

      final paneId = crux.PaneId.generate();
      final paneContainer = panes.containerFor(paneId);
      paneContainer
          .read(paneRenderStatsProvider.notifier)
          .recordPaint(paintMs: 3, when: DateTime(2026));
      expect(
        paneContainer.read(paneRenderStatsProvider).sampleCount,
        1,
      );
    });
  });
}
