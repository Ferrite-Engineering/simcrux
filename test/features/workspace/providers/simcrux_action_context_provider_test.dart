// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// Regression pins for the 2026-07-30 "Run Regression permanently
/// disabled" bug.
///
/// Opening a config (CLI positional arg or File → Open Config…) loaded
/// the tab fine, but Tools → Run Regression stayed greyed out forever.
/// Root cause: `activeTabActionFlagsProvider` (the root-scope mirror
/// behind `simcruxActionContextProvider`) materializes in the ROOT
/// `ProviderContainer`, while `bootstrap()` bound
/// `workspaceContainerManagersProvider` only in the scoped CHILD
/// container handed to `runApp`. The mirror's
/// `ref.watch(workspaceContainerManagersProvider)` therefore hit the
/// root's throwing default, the "unbound in widget tests" `try/catch`
/// swallowed it, and every per-tab flag — `hasConfig` included — stayed
/// false for the whole session.
///
/// These tests exercise the REAL production topology through
/// [createWorkspaceContainers] (the extracted `bootstrap()` wiring), so
/// a scoped-only managers binding fails here instead of only in a
/// release build.
library;

import 'dart:io';

import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_context.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_descriptors.dart';
import 'package:simcrux/features/config/providers/config_loader_provider.dart';
import 'package:simcrux/features/dashboard/providers/regression_runner.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/simcrux_action_context_provider.dart';
import 'package:simcrux/features/workspace/providers/workspace_containers.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/services/simcrux_workspace_codec.dart';
import 'package:simcrux/services/config/config_loader.dart';

import '../../../support/answered_telemetry.dart';

/// Minimal parseable config, mirroring `auto_run_on_open_test.dart`.
const _yaml = '''
version: "1"

defaults:
  simulator: icarus
  timeout: 300s
  pass_fail:
    type: exit_code

suites:
  smoke:
    sources:
      - tb/t1.v
      - tb/t2.v
    tests:
      - name: t1
        top: tb_t1
      - name: t2
        top: tb_t2
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'production topology: opening a config through the real open path '
    'flips hasConfig true and enables runRegression at root scope',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('simcrux_ctx_');
      final containers = createWorkspaceContainers(
        rootOverrides: [
          ...answeredTelemetryOverrides(),
          simcruxWorkspaceServiceProvider.overrideWithValue(
            crux.WorkspaceService<SimcruxTabPayload>(
              codec: const SimcruxWorkspaceCodec(),
              directoryFactory: () async => tempDir,
            ),
          ),
          configLoaderProvider.overrideWithValue(
            ConfigLoader(readFile: (_) async => _yaml),
          ),
        ],
      );
      final scoped = containers.scoped;
      addTearDown(() async {
        await scoped.read(workspaceProvider.notifier).flushPendingSave();
        scoped.dispose();
        containers.managers.dispose();
        containers.root.dispose();
        if (tempDir.existsSync()) await tempDir.delete(recursive: true);
      });

      await scoped.read(workspaceProvider.future);

      // Keep the context (and thus the flags mirror) alive exactly the way
      // the menu bar / toolbar / palette surfaces do — via a live watch
      // through the scoped container handed to runApp.
      final sub = scoped.listen(simcruxActionContextProvider, (_, _) {});
      addTearDown(sub.close);

      final cold = scoped.read(simcruxActionContextProvider);
      expect(cold.hasOpenTab, isFalse);
      expect(cold.hasConfig, isFalse);
      expect(isActionEnabled(SimcruxAction.runRegression, cold), isFalse);

      // File → Open Config… : the picker handler opens a workspace tab whose
      // payload carries the picked path…
      final tabId = await scoped
          .read(workspaceProvider.notifier)
          .openTab(
            displayName: 'simcrux.yaml',
            payload: SimcruxTabPayload(configPath: '/p/simcrux.yaml'),
          );
      // Let the flags mirror rebind to the new active tab.
      await Future<void>.delayed(Duration.zero);

      // …then RegressionTabContent mounts and loads the config through the
      // per-tab runner, which publishes it to the tab's activeConfigProvider.
      final tabContainer = containers.managers.tabs.containerFor(tabId);
      await tabContainer
          .read(regressionRunnerProvider.notifier)
          .startFromConfigPath('/p/simcrux.yaml', autoStart: false);

      // The mirror applies cross-container updates on a microtask; flush.
      await Future<void>.delayed(Duration.zero);

      final ctx = scoped.read(simcruxActionContextProvider);
      expect(ctx.hasOpenTab, isTrue);
      expect(
        ctx.hasConfig,
        isTrue,
        reason:
            "The root-scope action context must mirror the active tab's "
            'loaded config; if this is false the managers provider is not '
            'resolvable from the ROOT container and every run action is '
            'permanently disabled.',
      );
      expect(
        isActionEnabled(SimcruxAction.runRegression, ctx),
        isTrue,
        reason: 'Tools → Run Regression must light up once a config is open.',
      );
      expect(
        isActionEnabled(SimcruxAction.cancelRegression, ctx),
        isFalse,
        reason: 'No run is in flight yet.',
      );
    },
  );

  group('dispatch table', () {
    test('runRegression is enabled with a config open and idle runner', () {
      const ctx = SimcruxActionContext(hasOpenTab: true, hasConfig: true);
      expect(isActionEnabled(SimcruxAction.runRegression, ctx), isTrue);
    });

    test('runRegression is disabled without a config or during a run', () {
      const noConfig = SimcruxActionContext(hasOpenTab: true);
      expect(isActionEnabled(SimcruxAction.runRegression, noConfig), isFalse);

      const running = SimcruxActionContext(
        hasOpenTab: true,
        hasConfig: true,
        runInProgress: true,
      );
      expect(isActionEnabled(SimcruxAction.runRegression, running), isFalse);
      expect(isActionEnabled(SimcruxAction.cancelRegression, running), isTrue);
    });
  });
}
