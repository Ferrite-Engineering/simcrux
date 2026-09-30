// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'dart:io';

import 'package:crux_workspace/crux_workspace.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/services/simcrux_workspace_codec.dart';

import '../../../support/answered_telemetry.dart';

/// Regression coverage for the structural scope-eviction wiring that
/// `bootstrap()` installs in `lib/app.dart`
/// (`addScopeReconciler(managers.tabs)` / `(managers.panes)`).
///
/// Nothing fails to *compile* when a product forgets to register its
/// container managers — which is exactly why the wiring needs a test.
/// Skipping it costs two distinct bugs:
///
/// 1. **Leak.** A closed tab's `ProviderContainer` is never disposed, so
///    every provider, stream subscription and timer it holds survives
///    for the process lifetime.
/// 2. **Resurrection.** `TabId`s round-trip through `workspace.json`, so
///    reloading a saved workspace revives an id the manager still holds
///    a container for, and the "new" tab silently inherits the dead
///    tab's state — cross-tab bleed, not just memory growth.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('workspace scope reconcilers', () {
    late Directory tempDir;
    late WorkspaceService<SimcruxTabPayload> service;
    late ProviderContainer root;
    late TabContainerManager tabs;
    late PaneContainerManager panes;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('simcrux-scope-');
      service = WorkspaceService<SimcruxTabPayload>(
        codec: const SimcruxWorkspaceCodec(),
        directoryFactory: () async => tempDir,
      );
      root = ProviderContainer(
        overrides: [
          ...answeredTelemetryOverrides(),
          simcruxWorkspaceServiceProvider.overrideWithValue(service),
        ],
      );
      tabs = TabContainerManager(rootContainer: root);
      panes = PaneContainerManager(rootContainer: root);
      // Mirrors bootstrap(): register BEFORE hydration so the notifier's
      // own build-time snapshot already prunes the managers.
      root.read(workspaceProvider.notifier)
        ..addScopeReconciler(tabs)
        ..addScopeReconciler(panes);
      await root.read(workspaceProvider.future);
    });

    tearDown(() async {
      await root.read(workspaceProvider.notifier).flushPendingSave();
      tabs.dispose();
      panes.dispose();
      root.dispose();
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });

    test('closing a tab disposes its container', () async {
      final notifier = root.read(workspaceProvider.notifier);
      final id = await notifier.openTab(
        displayName: 'cpu.yaml',
        payload: SimcruxTabPayload(configPath: '/p/cpu.yaml'),
      );
      tabs.containerFor(id);
      expect(tabs.hasContainerFor(id), isTrue);

      await notifier.closeTab(id);
      expect(
        tabs.hasContainerFor(id),
        isFalse,
        reason: 'closed tab kept its ProviderContainer — reconciler not wired',
      );
    });

    test('closing a pane disposes its container', () async {
      final notifier = root.read(workspaceProvider.notifier);
      final paneId = await notifier.splitPaneRight();
      panes.containerFor(paneId);
      expect(panes.hasContainerFor(paneId), isTrue);

      await notifier.closePane(paneId);
      expect(panes.hasContainerFor(paneId), isFalse);
    });

    test('a revived tab id gets a FRESH container, not the dead one', () async {
      final notifier = root.read(workspaceProvider.notifier);
      final id = await notifier.openTab(
        displayName: 'cpu.yaml',
        payload: SimcruxTabPayload(configPath: '/p/cpu.yaml'),
      );
      final before = tabs.containerFor(id);

      // Capture the document, then wholesale-replace the workspace with
      // one reusing the SAME TabId — the resurrection scenario a
      // workspace reload produces.
      final saved = await root.read(workspaceProvider.future);
      await notifier.resetWorkspace();
      expect(
        tabs.hasContainerFor(id),
        isFalse,
        reason: 'replacement must evict every scope before reinstating ids',
      );

      await notifier.replaceWith(saved);
      final after = tabs.containerFor(id);
      expect(
        identical(after, before),
        isFalse,
        reason: 'revived tab inherited the dead tab container — state bleed',
      );
    });
  });
}
