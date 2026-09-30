// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// Coverage for [SimcruxWorkspaceNotifier.restoreGate] — the injection seam
/// `bootstrap()` uses under `--no-restore` (ported from WaveCrux's launch
/// recovery CLI contract; mirrors `NetcruxWorkspaceNotifier.restoreGate`).
library;

import 'dart:io';

import 'package:crux_workspace/crux_workspace.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/services/simcrux_workspace_codec.dart';

import '../../../support/answered_telemetry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('simcrux-restore-gate-');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  File documentFile() => File(p.join(tempDir.path, 'workspace.json'));

  WorkspaceService<SimcruxTabPayload> newService() =>
      WorkspaceService<SimcruxTabPayload>(
        codec: const SimcruxWorkspaceCodec(),
        directoryFactory: () async => tempDir,
        logger: (_) {},
      );

  /// One application launch over the same storage directory. [restoreGate]
  /// mimics `bootstrap()`'s `--no-restore` override when non-null.
  Future<Workspace<SimcruxTabPayload>> launch({
    Future<bool> Function()? restoreGate,
    List<String> openPaths = const [],
  }) async {
    final container = ProviderContainer(
      overrides: [
        ...answeredTelemetryOverrides(),
        simcruxWorkspaceServiceProvider.overrideWithValue(newService()),
        if (restoreGate != null)
          workspaceProvider.overrideWith(
            () => SimcruxWorkspaceNotifier(restoreGate: restoreGate),
          ),
      ],
    );
    try {
      await container.read(workspaceProvider.future);
      final notifier = container.read(workspaceProvider.notifier);
      for (final path in openPaths) {
        await notifier.openTab(
          displayName: p.basename(path),
          payload: SimcruxTabPayload(configPath: path),
        );
      }
      await notifier.flushPendingSave();
      return container.read(workspaceProvider).requireValue;
    } finally {
      container.dispose();
    }
  }

  test('a false restore gate starts with no tabs', () async {
    await launch(openPaths: [p.join(tempDir.path, 'cpu', 'simcrux.yaml')]);

    final ws = await launch(restoreGate: () async => false);

    expect(ws.tabs, isEmpty);
  });

  test('a false restore gate leaves the persisted document intact', () async {
    await launch(openPaths: [p.join(tempDir.path, 'cpu', 'simcrux.yaml')]);
    final before = documentFile().readAsStringSync();

    await launch(restoreGate: () async => false);

    expect(
      documentFile().readAsStringSync(),
      before,
      reason:
          '--no-restore skips this launch only; the next normal launch '
          'must be able to bring the session back.',
    );
  });

  test('a true restore gate restores the persisted tabs', () async {
    final config = p.join(tempDir.path, 'cpu', 'simcrux.yaml');
    await launch(openPaths: [config]);

    final ws = await launch(restoreGate: () async => true);

    expect(ws.tabs, hasLength(1));
    expect(ws.tabs.single.payload.configPath, config);
  });
}
