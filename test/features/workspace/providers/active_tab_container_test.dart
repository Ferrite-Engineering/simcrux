// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/active_tab_container.dart';
import 'package:simcrux/features/workspace/providers/container_managers.dart';
import 'package:simcrux/features/workspace/providers/simcrux_tab_overrides.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/services/simcrux_workspace_codec.dart';

import '../../../support/answered_telemetry.dart';

/// Probe provider whose body resolves the active tab container so the
/// helper can be exercised through a real `Ref`.
final Provider<ProviderContainer?> _probeProvider =
    Provider<ProviderContainer?>(activeTabContainerOf);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('returns null when the container managers are not bound', () {
    final container = ProviderContainer(
      overrides: answeredTelemetryOverrides(),
    );
    addTearDown(container.dispose);
    expect(container.read(_probeProvider), isNull);
  });

  test('returns null before the workspace hydrates or a tab activates, '
      "then the active tab's container once one exists", () async {
    final tempDir = await Directory.systemTemp.createTemp('simcrux_atc_');
    late final ProviderContainer container;
    final managersCreated = <WorkspaceContainerManagers>[];
    container = ProviderContainer(
      overrides: [
        ...answeredTelemetryOverrides(),
        simcruxWorkspaceServiceProvider.overrideWithValue(
          crux.WorkspaceService<SimcruxTabPayload>(
            codec: const SimcruxWorkspaceCodec(),
            directoryFactory: () async => tempDir,
          ),
        ),
        workspaceContainerManagersProvider.overrideWith((ref) {
          final managers = WorkspaceContainerManagers(
            tabs: crux.TabContainerManager(
              rootContainer: container,
              overridesFactory: simcruxTabOverrides,
            ),
            panes: crux.PaneContainerManager(rootContainer: container),
          );
          managersCreated.add(managers);
          return managers;
        }),
      ],
    );
    addTearDown(() async {
      await container.read(workspaceProvider.notifier).flushPendingSave();
      for (final m in managersCreated) {
        m.dispose();
      }
      container.dispose();
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });

    // Pre-hydration: no workspace value yet.
    expect(container.read(_probeProvider), isNull);

    await container.read(workspaceProvider.future);
    final tabId = await container
        .read(workspaceProvider.notifier)
        .openTab(
          displayName: 'a',
          payload: SimcruxTabPayload(configPath: '/p/a.yaml'),
        );

    // The probe provider is a plain Provider — invalidate to
    // re-resolve after the workspace mutation.
    container.invalidate(_probeProvider);
    final resolved = container.read(_probeProvider);
    expect(resolved, isNotNull);
    expect(
      identical(
        resolved,
        container
            .read(workspaceContainerManagersProvider)
            .tabs
            .containerFor(tabId),
      ),
      isTrue,
      reason: "the helper must return the active tab's cached container",
    );
  });
}
