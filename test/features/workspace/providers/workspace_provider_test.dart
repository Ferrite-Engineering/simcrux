// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_workspace/crux_workspace.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/services/simcrux_workspace_codec.dart';

import '../../../support/answered_telemetry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('workspaceProvider', () {
    late Directory tempDir;
    late WorkspaceService<SimcruxTabPayload> service;
    late ProviderContainer container;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('simcrux-ws-');
      service = WorkspaceService<SimcruxTabPayload>(
        codec: const SimcruxWorkspaceCodec(),
        directoryFactory: () async => tempDir,
      );
      container = ProviderContainer(
        overrides: [
          ...answeredTelemetryOverrides(),
          simcruxWorkspaceServiceProvider.overrideWithValue(service),
        ],
      );
    });

    tearDown(() async {
      // Flush any debounced save so the teardown's temp-dir wipe does
      // not race a delayed write attempt.
      await container.read(workspaceProvider.notifier).flushPendingSave();
      container.dispose();
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('first build returns the empty workspace', () async {
      final ws = await container.read(workspaceProvider.future);
      expect(ws.tabs, isEmpty);
      expect(ws.panes, hasLength(1));
      expect(ws.activePaneId, ws.panes.single.id);
    });

    test('openTab + closeTab round-trips via the package API', () async {
      // Make sure the build has resolved first.
      await container.read(workspaceProvider.future);
      final notifier = container.read(workspaceProvider.notifier);
      final id = await notifier.openTab(
        displayName: 'cpu.yaml',
        payload: SimcruxTabPayload(configPath: '/p/cpu.yaml'),
      );
      var ws = await container.read(workspaceProvider.future);
      expect(ws.tabs, hasLength(1));
      expect(ws.tabs.single.id, id);
      expect(ws.tabs.single.payload.configPath, '/p/cpu.yaml');

      await notifier.closeTab(id);
      ws = await container.read(workspaceProvider.future);
      expect(ws.tabs, isEmpty);
    });

    test('updateTabPayload mutates the payload in place', () async {
      await container.read(workspaceProvider.future);
      final notifier = container.read(workspaceProvider.notifier);
      final id = await notifier.openTab(
        displayName: 'cpu.yaml',
        payload: SimcruxTabPayload(configPath: '/p/cpu.yaml'),
      );
      await notifier.updateTabPayload(
        id,
        (p) => p.copyWith(selectedTestId: 'alu/add'),
      );
      final ws = await container.read(workspaceProvider.future);
      expect(ws.tabs.single.payload.selectedTestId, 'alu/add');
    });

    test('split + close round-trips back to a single pane', () async {
      await container.read(workspaceProvider.future);
      final notifier = container.read(workspaceProvider.notifier);
      // Need at least two tabs so split-pane actually splits (a sole
      // tab + split = no-op per the package contract).
      await notifier.openTab(
        displayName: 'cpu.yaml',
        payload: SimcruxTabPayload(configPath: '/p/cpu.yaml'),
      );
      await notifier.openTab(
        displayName: 'mem.yaml',
        payload: SimcruxTabPayload(configPath: '/p/mem.yaml'),
      );
      final newPaneId = await notifier.splitPaneRight();
      var ws = await container.read(workspaceProvider.future);
      expect(ws.panes, hasLength(2));
      expect(ws.activePaneId, newPaneId);

      await notifier.closePane(newPaneId);
      ws = await container.read(workspaceProvider.future);
      expect(ws.panes, hasLength(1));
      expect(ws.tabs, hasLength(2));
    });

    test('resetWorkspace produces the empty workspace', () async {
      await container.read(workspaceProvider.future);
      final notifier = container.read(workspaceProvider.notifier);
      await notifier.openTab(
        displayName: 'cpu.yaml',
        payload: SimcruxTabPayload(configPath: '/p/cpu.yaml'),
      );
      await notifier.resetWorkspace();
      final ws = await container.read(workspaceProvider.future);
      expect(ws.tabs, isEmpty);
    });

    test('per-tab payload mutations in one tab leave another tab '
        'untouched', () async {
      await container.read(workspaceProvider.future);
      final notifier = container.read(workspaceProvider.notifier);
      final a = await notifier.openTab(
        displayName: 'a.yaml',
        payload: SimcruxTabPayload(configPath: '/p/a.yaml'),
      );
      final b = await notifier.openTab(
        displayName: 'b.yaml',
        payload: SimcruxTabPayload(configPath: '/p/b.yaml'),
      );
      await notifier.updateTabPayload(
        a,
        (p) => p.copyWith(selectedTestId: 'alu/add'),
      );
      final ws = await container.read(workspaceProvider.future);
      final tabA = ws.tabs.firstWhere((t) => t.id == a);
      final tabB = ws.tabs.firstWhere((t) => t.id == b);
      expect(tabA.payload.selectedTestId, 'alu/add');
      expect(tabB.payload.selectedTestId, isNull);
    });
  });
}
