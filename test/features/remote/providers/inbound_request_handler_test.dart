// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'dart:io';

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_window_chrome/crux_window_chrome.dart';
import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/inspector/services/editor_launcher.dart';
import 'package:simcrux/features/inspector/services/editor_launcher_provider.dart';
import 'package:simcrux/features/remote/providers/cxp_discovery_provider.dart';
import 'package:simcrux/features/remote/providers/cxp_server_provider.dart';
import 'package:simcrux/features/remote/providers/inbound_request_handler.dart';
import 'package:simcrux/features/remote/providers/notify_selection_emitter.dart';
import 'package:simcrux/features/remote/services/cxp_workspace_link.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/container_managers.dart';
import 'package:simcrux/features/workspace/providers/simcrux_tab_overrides.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/services/simcrux_workspace_codec.dart';
import 'package:simcrux/services/remote/cxp/simcrux_cxp_discovery.dart';
import 'package:simcrux/services/remote/cxp/simcrux_cxp_server.dart';

import '../../../support/answered_telemetry.dart';
import '../../../support/cxp_fake_peer.dart';
import '../../../support/delete_manifest_dir.dart';
import '../../../support/poll_until.dart';

/// A single-suite config whose only test is `suiteA/testB`, used to
/// satisfy the handler's honest-ack existence check.
RegressionConfig _configWithTest(String testId) {
  final slash = testId.indexOf('/');
  final suiteName = testId.substring(0, slash);
  final name = testId.substring(slash + 1);
  return RegressionConfig(
    projectFilePath: '/p/a.yaml',
    schemaVersion: '1',
    suites: [
      Suite(
        name: suiteName,
        tests: [
          TestSpec(
            id: testId,
            name: name,
            suiteName: suiteName,
            simulatorId: 'icarus',
            top: 'tb',
          ),
        ],
      ),
    ],
    simulatorBinaries: const {},
  );
}

class _StubLauncher implements EditorLauncher {
  _StubLauncher({this.shouldSucceed = true});
  final bool shouldSucceed;
  final List<({String filePath, int line, int column})> calls = [];

  @override
  String get template => 'stub';

  @override
  ({String executable, List<String> args})? composeCommand({
    required String filePath,
    int line = 1,
    int column = 1,
  }) => (executable: 'stub', args: const <String>[]);

  @override
  Future<bool> openSource({
    required String filePath,
    int line = 1,
    int column = 1,
  }) async {
    calls.add((filePath: filePath, line: line, column: column));
    return shouldSucceed;
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // The inbound handler fires `requestUserAttention()` on honored
    // messages. These are binding-less `dart:test` cases, so the default
    // method-channel backend would throw on the missing ServicesBinding —
    // gate it to the no-op backend exactly as the settings bridge does when
    // the preference is off.
    windowAttentionRequester = const NoopWindowAttentionRequester();
  });

  tearDown(() {
    windowAttentionRequester = const MethodChannelWindowAttentionRequester();
  });

  Future<
    ({
      ProviderContainer container,
      LocalCxpClient client,
      SimCruxCxpServer server,
      _StubLauncher launcher,
    })
  >
  wireClient({
    bool launcherSucceeds = true,
    String? openedConfig,
    CxpWorkspaceStore? workspaceStore,
    bool anchorBeforeServer = false,
  }) async {
    final launcher = _StubLauncher(shouldSucceed: launcherSucceeds);
    final container = ProviderContainer(
      overrides: <Override>[
        ...answeredTelemetryOverrides(),
        // A server with no containment of its own — the floor rule only — so
        // a path that is absolute but outside the opened directories reaches
        // the handler, and the handler's own CXP §11 check is what is tested.
        cxpServerFactoryProvider.overrideWithValue(
          ({required selfIdentity, required port}) => SimCruxCxpServer(
            selfIdentity: selfIdentity,
            port: 0,
          ),
        ),
        editorLauncherProvider.overrideWithValue(launcher),
        if (workspaceStore != null)
          cxpWorkspaceStoreProvider.overrideWithValue(workspaceStore),
      ],
    );
    // The app anchors the handler at startup, before the server has bound:
    // that ordering is the one production runs.
    if (anchorBeforeServer) container.read(inboundRequestHandlerProvider);
    await container.read(appSettingsProvider.future);
    // The user has opened a config under `/abs` — the recent-projects list is
    // one of the sources of CXP §11's containment roots, so every
    // peer-supplied path below `/abs` is inside the rule and everything else
    // is refused. Seeding it here, rather than overriding the containment
    // provider, keeps the production roots in the path under test.
    await container
        .read(appSettingsProvider.notifier)
        .addRecentProject(openedConfig ?? _abs('/abs/simcrux.yaml'));
    final server = await container.read(cxpServerProvider.future);
    expect(server, isNotNull);

    // Anchor the handler.
    container.read(inboundRequestHandlerProvider);

    final client = LocalCxpClient(
      selfIdentity: const PeerIdentity(
        peerId: 'test-inbound-client',
        productName: 'test',
        productVersion: '0.0.0',
      ),
    );
    await client.connect(
      host: '127.0.0.1',
      port: server!.boundPort!,
      token: cxpProcessAuthToken,
    );
    return (
      container: container,
      client: client,
      server: server,
      launcher: launcher,
    );
  }

  test('a handler anchored before the server bound still answers', () async {
    // The app anchors the handler at startup, while the server is still
    // binding. attach() returned on "no server yet" before registering the
    // listener that picks the server up, so no inbound request was ever
    // dispatched or acknowledged; peers waited out their ack timeout.
    final wired = await wireClient(anchorBeforeServer: true);
    addTearDown(() async {
      await wired.client.dispose();
      wired.container.dispose();
    });
    wired.container
        .read(activeConfigProvider.notifier)
        .replace(_configWithTest('suiteA/testB'));

    final ackFuture = wired.client.inbound.firstWhere(
      (m) => m.message is RequestHighlightAck,
    );
    wired.client.send(
      const RequestHighlight(
        element: ElementId(kind: ElementKind.test, path: 'suiteA/testB'),
      ),
    );
    final ack =
        (await ackFuture.timeout(const Duration(seconds: 2))).message
            as RequestHighlightAck;
    expect(ack.honored, isTrue);
  });

  group('RequestHighlight — ElementKind.test', () {
    test('selects the named test in the dashboard when it exists in '
        'the loaded config', () async {
      final wired = await wireClient();
      addTearDown(() async {
        await wired.client.dispose();
        wired.container.dispose();
      });
      wired.container
          .read(activeConfigProvider.notifier)
          .replace(_configWithTest('suiteA/testB'));

      final ackFuture = wired.client.inbound.firstWhere(
        (m) => m.message is RequestHighlightAck,
      );
      wired.client.send(
        const RequestHighlight(
          element: ElementId(kind: ElementKind.test, path: 'suiteA/testB'),
        ),
      );
      final ack =
          (await ackFuture.timeout(const Duration(seconds: 2))).message
              as RequestHighlightAck;
      expect(ack.honored, isTrue);
      expect(
        wired.container.read(selectedTestIdProvider),
        'suiteA/testB',
      );
    });

    test('acks honored:false when the named test is not in the loaded '
        'config (honest ack — no silent-success lie)', () async {
      final wired = await wireClient();
      addTearDown(() async {
        await wired.client.dispose();
        wired.container.dispose();
      });
      wired.container
          .read(activeConfigProvider.notifier)
          .replace(_configWithTest('suiteA/testB'));

      final ackFuture = wired.client.inbound.firstWhere(
        (m) => m.message is RequestHighlightAck,
      );
      wired.client.send(
        const RequestHighlight(
          element: ElementId(kind: ElementKind.test, path: 'suiteA/nope'),
        ),
      );
      final ack =
          (await ackFuture.timeout(const Duration(seconds: 2))).message
              as RequestHighlightAck;
      expect(ack.honored, isFalse);
      expect(ack.reason, contains('not found'));
      expect(wired.container.read(selectedTestIdProvider), isNull);
    });

    test('acks honored:false when no config is loaded', () async {
      final wired = await wireClient();
      addTearDown(() async {
        await wired.client.dispose();
        wired.container.dispose();
      });

      final ackFuture = wired.client.inbound.firstWhere(
        (m) => m.message is RequestHighlightAck,
      );
      wired.client.send(
        const RequestHighlight(
          element: ElementId(kind: ElementKind.test, path: 'suiteA/testB'),
        ),
      );
      final ack =
          (await ackFuture.timeout(const Duration(seconds: 2))).message
              as RequestHighlightAck;
      expect(ack.honored, isFalse);
      expect(wired.container.read(selectedTestIdProvider), isNull);
    });
  });

  group('active-tab routing (workspace mounted)', () {
    test('RequestHighlight (test) mutates the ACTIVE tab container, '
        'not the dormant root instances', () async {
      final tempDir = await Directory.systemTemp.createTemp('simcrux_cxp_ws_');
      final launcher = _StubLauncher();
      late final ProviderContainer container;
      final managersCompleter = <WorkspaceContainerManagers>[];
      container = ProviderContainer(
        overrides: <Override>[
          ...answeredTelemetryOverrides(),
          cxpServerFactoryProvider.overrideWithValue(
            ({required selfIdentity, required port}) => SimCruxCxpServer(
              selfIdentity: selfIdentity,
              port: 0,
            ),
          ),
          editorLauncherProvider.overrideWithValue(launcher),
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
            managersCompleter.add(managers);
            return managers;
          }),
        ],
      );
      addTearDown(() async {
        // Land the debounced workspace save before the temp dir goes
        // away so teardown doesn't race the writer.
        await container.read(workspaceProvider.notifier).flushPendingSave();
        for (final m in managersCompleter) {
          m.dispose();
        }
        container.dispose();
        if (tempDir.existsSync()) await tempDir.delete(recursive: true);
      });

      await container.read(appSettingsProvider.future);
      final server = await container.read(cxpServerProvider.future);
      expect(server, isNotNull);
      container.read(inboundRequestHandlerProvider);

      // Hydrate the workspace and open one tab; it becomes active.
      await container.read(workspaceProvider.future);
      final tabId = await container
          .read(workspaceProvider.notifier)
          .openTab(
            displayName: 'a',
            payload: SimcruxTabPayload(configPath: '/p/a.yaml'),
          );
      final managers = container.read(workspaceContainerManagersProvider);
      final tabContainer = managers.tabs.containerFor(tabId);
      // Load the tab's config into the per-tab scope, the way the
      // runner does on project open.
      tabContainer
          .read(activeConfigProvider.notifier)
          .replace(_configWithTest('suiteA/testB'));

      final client = LocalCxpClient(
        selfIdentity: const PeerIdentity(
          peerId: 'test-inbound-client',
          productName: 'test',
          productVersion: '0.0.0',
        ),
      );
      addTearDown(client.dispose);
      await client.connect(
        host: '127.0.0.1',
        port: server!.boundPort!,
        token: cxpProcessAuthToken,
      );

      final ackFuture = client.inbound.firstWhere(
        (m) => m.message is RequestHighlightAck,
      );
      client.send(
        const RequestHighlight(
          element: ElementId(kind: ElementKind.test, path: 'suiteA/testB'),
        ),
      );
      final ack =
          (await ackFuture.timeout(const Duration(seconds: 2))).message
              as RequestHighlightAck;
      expect(ack.honored, isTrue);
      expect(
        tabContainer.read(selectedTestIdProvider),
        'suiteA/testB',
        reason: 'selection must land in the ACTIVE tab container',
      );
      expect(
        container.read(selectedTestIdProvider),
        isNull,
        reason: 'the dormant root instance must stay untouched',
      );

      // Filter-shaped highlight lands in the active tab too.
      final filterAckFuture = client.inbound.firstWhere(
        (m) =>
            m.message is RequestHighlightAck &&
            m.message != ack, // a second ack
      );
      client.send(
        const RequestHighlight(
          element: ElementId(
            kind: ElementKind.signal,
            path: 'top.cpu.alu.sum[31:0]',
          ),
        ),
      );
      await filterAckFuture.timeout(const Duration(seconds: 2));
      expect(
        tabContainer.read(dashboardFilterProvider).testNameSubstring,
        'sum',
      );
      expect(
        container.read(dashboardFilterProvider).testNameSubstring,
        isEmpty,
      );
    });

    test(
      'RequestHighlight arriving over a REAL connector-dialed link (a '
      'full peer product, not a raw client) still mutates the ACTIVE tab '
      "container, and the peer's own server.inbound genuinely receives "
      'the ack back — the flagship CXP path end to end',
      () async {
        // Separate directories: the workspace's own persisted state and
        // the CXP-shared manifest scan directory are unrelated concerns
        // and must not intermix.
        final tempDir = await Directory.systemTemp.createTemp(
          'simcrux_cxp_ws_e2e_',
        );
        final manifestDir = await Directory.systemTemp.createTemp(
          'simcrux_cxp_manifest_e2e_',
        );
        final launcher = _StubLauncher();
        late final ProviderContainer container;
        final managersCompleter = <WorkspaceContainerManagers>[];
        container = ProviderContainer(
          overrides: <Override>[
            ...answeredTelemetryOverrides(),
            cxpServerFactoryProvider.overrideWithValue(
              ({required selfIdentity, required port}) => SimCruxCxpServer(
                selfIdentity: selfIdentity,
                port: 0,
              ),
            ),
            cxpDiscoveryFactoryProvider.overrideWithValue(
              () async => SimCruxCxpDiscoveryService(
                manifestDirectory: manifestDir.path,
                scanInterval: const Duration(milliseconds: 30),
              ),
            ),
            editorLauncherProvider.overrideWithValue(launcher),
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
              managersCompleter.add(managers);
              return managers;
            }),
          ],
        );
        addTearDown(() async {
          await container.read(workspaceProvider.notifier).flushPendingSave();
          for (final m in managersCompleter) {
            m.dispose();
          }
          container.dispose();
          if (tempDir.existsSync()) await tempDir.delete(recursive: true);
          deleteManifestDir(manifestDir);
        });

        await container.read(appSettingsProvider.future);
        final server = await container.read(cxpServerProvider.future);
        expect(server, isNotNull);
        await container.read(cxpDiscoveryProvider.future);
        container.read(inboundRequestHandlerProvider);

        await container.read(workspaceProvider.future);
        final tabId = await container
            .read(workspaceProvider.notifier)
            .openTab(
              displayName: 'a',
              payload: SimcruxTabPayload(configPath: '/p/a.yaml'),
            );
        final managers = container.read(workspaceContainerManagersProvider);
        final tabContainer = managers.tabs.containerFor(tabId);
        tabContainer
            .read(activeConfigProvider.notifier)
            .replace(_configWithTest('suiteA/testB'));

        const waveId = PeerIdentity(
          peerId: 'wavecrux-inbound-e2e-1',
          productName: 'wavecrux',
          productVersion: '0.3.0',
        );
        final peer = await CxpFakePeer.start(
          identity: waveId,
          manifestDirectory: manifestDir.path,
        );
        addTearDown(peer.stop);

        final mutual = await pollUntil(
          () =>
              server!.connectedPeers.any((p) => p.peerId == waveId.peerId) &&
              peer.isConnectedTo(server.selfIdentity.peerId),
        );
        expect(
          mutual,
          isTrue,
          reason: 'expected mutual connect before probing',
        );

        // Peer originates — the same shape a real WaveCrux "Debug in
        // SimCrux" (or equivalent) cross-probe would send.
        final delivered = peer.server.sendTo(
          server!.selfIdentity.peerId,
          const RequestHighlight(
            element: ElementId(kind: ElementKind.test, path: 'suiteA/testB'),
          ),
        );
        expect(delivered, isTrue);

        final selected = await pollUntil(
          () => tabContainer.read(selectedTestIdProvider) == 'suiteA/testB',
        );
        expect(
          selected,
          isTrue,
          reason:
              'selection must land in the ACTIVE tab container even '
              'when the request arrives over a connector-dialed link',
        );
        expect(
          container.read(selectedTestIdProvider),
          isNull,
          reason: 'the dormant root instance must stay untouched',
        );

        // The ack SimCrux's handler sent back must reach the PEER's own
        // product-level inbound stream — proving the round trip, not
        // just that the inbound side mutated local state.
        final gotAck = await pollUntil(
          () => peer.received.any((m) => m.message is RequestHighlightAck),
        );
        expect(
          gotAck,
          isTrue,
          reason: "the ack must route back to the peer's own server.inbound",
        );
        final ack =
            peer.received
                    .firstWhere((m) => m.message is RequestHighlightAck)
                    .message
                as RequestHighlightAck;
        expect(ack.honored, isTrue);
      },
    );
  });

  group('RequestHighlight — ElementKind.source', () {
    test('records an explicit source selection', () async {
      final wired = await wireClient();
      addTearDown(() async {
        await wired.client.dispose();
        wired.container.dispose();
      });

      final ackFuture = wired.client.inbound.firstWhere(
        (m) => m.message is RequestHighlightAck,
      );
      wired.client.send(
        const RequestHighlight(
          element: ElementId(
            kind: ElementKind.source,
            path: '/abs/rtl/alu.sv',
          ),
        ),
      );
      final ack =
          (await ackFuture.timeout(const Duration(seconds: 2))).message
              as RequestHighlightAck;
      expect(ack.honored, isTrue);
      expect(
        wired.container.read(explicitSourceSelectionProvider),
        '/abs/rtl/alu.sv',
      );
    });
  });

  group('RequestHighlight — ElementKind.signal / instance', () {
    test('filters the dashboard to the leaf identifier', () async {
      final wired = await wireClient();
      addTearDown(() async {
        await wired.client.dispose();
        wired.container.dispose();
      });

      wired.client.send(
        const RequestHighlight(
          element: ElementId(
            kind: ElementKind.signal,
            path: 'top.cpu.alu.sum[31:0]',
          ),
        ),
      );
      // Wait for the ack so we know the handler completed.
      await wired.client.inbound
          .firstWhere(
            (m) => m.message is RequestHighlightAck,
          )
          .timeout(const Duration(seconds: 2));
      expect(
        wired.container.read(dashboardFilterProvider).testNameSubstring,
        'sum',
      );
    });

    test('uses instance leaf when given ElementKind.instance', () async {
      final wired = await wireClient();
      addTearDown(() async {
        await wired.client.dispose();
        wired.container.dispose();
      });

      wired.client.send(
        const RequestHighlight(
          element: ElementId(
            kind: ElementKind.instance,
            path: 'top.cpu.alu',
          ),
        ),
      );
      await wired.client.inbound
          .firstWhere(
            (m) => m.message is RequestHighlightAck,
          )
          .timeout(const Duration(seconds: 2));
      expect(
        wired.container.read(dashboardFilterProvider).testNameSubstring,
        'alu',
      );
    });
  });

  group('RequestHighlight — ElementKind.breakpoint', () {
    test('replies honored: false with a reason', () async {
      final wired = await wireClient();
      addTearDown(() async {
        await wired.client.dispose();
        wired.container.dispose();
      });

      final ackFuture = wired.client.inbound.firstWhere(
        (m) => m.message is RequestHighlightAck,
      );
      wired.client.send(
        const RequestHighlight(
          element: ElementId(
            kind: ElementKind.breakpoint,
            path: '/abs/tb_x.v:42',
          ),
        ),
      );
      final ack =
          (await ackFuture.timeout(const Duration(seconds: 2))).message
              as RequestHighlightAck;
      expect(ack.honored, isFalse);
      expect(ack.reason, contains('breakpoint editor'));
    });
  });

  group('RequestHighlight — ElementKind.marker / rule', () {
    test('replies honored: false with a clear reason', () async {
      final wired = await wireClient();
      addTearDown(() async {
        await wired.client.dispose();
        wired.container.dispose();
      });

      final ackFuture = wired.client.inbound.firstWhere(
        (m) => m.message is RequestHighlightAck,
      );
      wired.client.send(
        const RequestHighlight(
          element: ElementId(kind: ElementKind.marker, path: 'a'),
        ),
      );
      final ack =
          (await ackFuture.timeout(const Duration(seconds: 2))).message
              as RequestHighlightAck;
      expect(ack.honored, isFalse);
      expect(ack.reason, contains('marker'));
    });
  });

  group('RequestHighlight — unknown ElementKind', () {
    test(
      'ignores gracefully with honored: false instead of throwing',
      () async {
        // `ElementKind` is an open wire type: a peer built against a later
        // protocol revision can name a kind this build has never heard of.
        // The forward-compatible contract is to decline politely, not to
        // blow up the inbound dispatch loop.
        final wired = await wireClient();
        addTearDown(() async {
          await wired.client.dispose();
          wired.container.dispose();
        });

        final ackFuture = wired.client.inbound.firstWhere(
          (m) => m.message is RequestHighlightAck,
        );
        wired.client.send(
          RequestHighlight(
            element: ElementId(
              kind: ElementKind('quantum_flux_capacitor'),
              path: 'top.dut.thing',
            ),
          ),
        );
        final ack =
            (await ackFuture.timeout(const Duration(seconds: 2))).message
                as RequestHighlightAck;
        expect(ack.honored, isFalse);
        expect(ack.reason, contains('quantum_flux_capacitor'));
      },
    );

    test('stays attached and serves the next known-kind request', () async {
      // The real regression risk is not the single bad message — it is
      // an unknown kind killing the subscription so every subsequent
      // request goes unanswered.
      final wired = await wireClient();
      addTearDown(() async {
        await wired.client.dispose();
        wired.container.dispose();
      });

      final firstAck = wired.client.inbound.firstWhere(
        (m) => m.message is RequestHighlightAck,
      );
      wired.client.send(
        RequestHighlight(
          element: ElementId(kind: ElementKind('not_a_real_kind'), path: 'x'),
        ),
      );
      await firstAck.timeout(const Duration(seconds: 2));

      final secondAck = wired.client.inbound.firstWhere(
        (m) => m.message is RequestHighlightAck,
      );
      wired.client.send(
        const RequestHighlight(
          element: ElementId(kind: ElementKind.marker, path: 'a'),
        ),
      );
      final ack =
          (await secondAck.timeout(const Duration(seconds: 2))).message
              as RequestHighlightAck;
      expect(ack.reason, contains('marker'));
    });
  });

  group('RequestOpenSource', () {
    test('shells to the editor and acks honored: true', () async {
      final wired = await wireClient();
      addTearDown(() async {
        await wired.client.dispose();
        wired.container.dispose();
      });

      final ackFuture = wired.client.inbound.firstWhere(
        (m) => m.message is RequestOpenSourceAck,
      );
      final alu = _abs('/abs/rtl/alu.sv');
      wired.client.send(RequestOpenSource(filePath: alu, line: 42, column: 8));
      final ack =
          (await ackFuture.timeout(const Duration(seconds: 2))).message
              as RequestOpenSourceAck;
      expect(ack.honored, isTrue);
      expect(wired.launcher.calls, hasLength(1));
      expect(wired.launcher.calls.single.filePath, alu);
      expect(wired.launcher.calls.single.line, 42);
      expect(wired.launcher.calls.single.column, 8);
    });

    test('acks honored: false when launcher fails', () async {
      final wired = await wireClient(launcherSucceeds: false);
      addTearDown(() async {
        await wired.client.dispose();
        wired.container.dispose();
      });

      final ackFuture = wired.client.inbound.firstWhere(
        (m) => m.message is RequestOpenSourceAck,
      );
      wired.client.send(
        RequestOpenSource(filePath: _abs('/abs/x.v'), line: 1),
      );
      final ack =
          (await ackFuture.timeout(const Duration(seconds: 2))).message
              as RequestOpenSourceAck;
      expect(ack.honored, isFalse);
      expect(ack.reason, contains('failed to launch'));
    });
  });

  // CXP §11. The server `wireClient` builds applies only the floor rule, so an
  // absolute path outside the opened directories reaches the handler: every
  // refusal below is the handler's own check on the value it is about to hand
  // to an editor argv.
  //
  // MUTATION: deleting any one of the three containment checks in
  // `InboundRequestHandler` (open-source, open-artifact, the highlight
  // fallback) turns the matching case red.
  group('CXP §11 containment', () {
    late Directory inside;
    late Directory outside;
    late Directory records;
    late String insideSource;
    late String outsideSource;
    late CxpWorkspaceStore store;

    setUp(() async {
      inside = await Directory.systemTemp.createTemp('simcrux_cxp_in_');
      outside = await Directory.systemTemp.createTemp('simcrux_cxp_out_');
      records = await Directory.systemTemp.createTemp('simcrux_cxp_ws_');
      insideSource = '${inside.path}/rtl/top.sv';
      outsideSource = '${outside.path}/rtl/evil.sv';
      for (final path in <String>[insideSource, outsideSource]) {
        await File(path).create(recursive: true);
      }
      // No containment on the store: it hands back whatever was recorded, so
      // the only thing between a record naming a directory the user never
      // opened and the editor is the handler's check.
      store = CxpWorkspaceStore(workspaceDirectory: records.path);
      await store.upsertArtifact(
        designId: cxpDesignIdForPath(inside.path),
        kind: kCxpSourceArtifactKind,
        path: insideSource,
        producer: 'peer',
      );
      await store.upsertArtifact(
        designId: cxpDesignIdForPath(outside.path),
        kind: kCxpSourceArtifactKind,
        path: outsideSource,
        producer: 'peer',
      );
    });

    tearDown(() async {
      for (final dir in <Directory>[inside, outside, records]) {
        if (dir.existsSync()) await dir.delete(recursive: true);
      }
    });

    Future<
      ({
        ProviderContainer container,
        LocalCxpClient client,
        SimCruxCxpServer server,
        _StubLauncher launcher,
      })
    >
    wireInside() async {
      final wired = await wireClient(
        openedConfig: '${inside.path}/simcrux.yaml',
        workspaceStore: store,
      );
      addTearDown(() async {
        await wired.client.dispose();
        wired.container.dispose();
      });
      return wired;
    }

    test('RequestOpenSource outside the opened directories is refused, and '
        'no editor runs', () async {
      final wired = await wireClient();
      addTearDown(() async {
        await wired.client.dispose();
        wired.container.dispose();
      });

      final ackFuture = wired.client.inbound.firstWhere(
        (m) => m.message is RequestOpenSourceAck,
      );
      final passwd = _abs('/etc/passwd');
      wired.client.send(RequestOpenSource(filePath: passwd, line: 1));
      final ack =
          (await ackFuture.timeout(const Duration(seconds: 2))).message
              as RequestOpenSourceAck;
      expect(ack.honored, isFalse);
      expect(ack.reason, contains('outside the directories'));
      // CXP §9.11: the reason never echoes the sender's path back.
      expect(ack.reason, isNot(contains(passwd)));
      expect(wired.launcher.calls, isEmpty);
    });

    test('RequestOpenArtifact opens a recorded source inside the opened '
        'directories and never one outside them', () async {
      final wired = await wireInside();
      final acks = <RequestOpenArtifactAck>[];
      wired.client.inbound.listen((m) {
        final message = m.message;
        if (message is RequestOpenArtifactAck) acks.add(message);
      });

      wired.client.send(
        RequestOpenArtifact(
          designId: cxpDesignIdForPath(outside.path),
          artifactKind: kCxpSourceArtifactKind,
        ),
      );
      expect(await pollUntil(() => acks.isNotEmpty), isTrue);
      expect(acks.single.honored, isFalse);
      expect(acks.single.reason, contains('outside the directories'));
      expect(wired.launcher.calls, isEmpty);

      wired.client.send(
        RequestOpenArtifact(
          designId: cxpDesignIdForPath(inside.path),
          artifactKind: kCxpSourceArtifactKind,
        ),
      );
      expect(await pollUntil(() => acks.length == 2), isTrue);
      expect(acks.last.honored, isTrue);
      expect(
        wired.launcher.calls.map((c) => c.filePath),
        <String>[insideSource],
      );
    });

    test('a RequestOpenArtifact path hint outside the opened directories is '
        'never opened', () async {
      final wired = await wireInside();
      final ackFuture = wired.client.inbound.firstWhere(
        (m) => m.message is RequestOpenArtifactAck,
      );
      // No record for this design, so the handler falls back to the hint.
      wired.client.send(
        const RequestOpenArtifact(
          designId: 'no-such-design',
          artifactKind: kCxpSourceArtifactKind,
          path: '/etc/passwd',
        ),
      );
      final ack =
          (await ackFuture.timeout(const Duration(seconds: 2))).message
              as RequestOpenArtifactAck;
      expect(ack.honored, isFalse);
      expect(wired.launcher.calls, isEmpty);
    });

    test('the highlight fallback never opens a recorded source outside the '
        'opened directories', () async {
      final wired = await wireInside();
      final acks = <RequestHighlightAck>[];
      wired.client.inbound.listen((m) {
        final message = m.message;
        if (message is RequestHighlightAck) acks.add(message);
      });

      // No config is loaded, so the test id cannot be honoured locally and
      // the handler falls back to the design the metadata names.
      RequestHighlight probe(String designId) => RequestHighlight(
        element: const ElementId(kind: ElementKind.test, path: 'suite/t'),
        metadata: <String, Object?>{cxpDesignIdMetadataKey: designId},
      );

      wired.client.send(probe(cxpDesignIdForPath(outside.path)));
      expect(await pollUntil(() => acks.isNotEmpty), isTrue);
      expect(acks.single.honored, isFalse);
      expect(wired.launcher.calls, isEmpty);

      wired.client.send(probe(cxpDesignIdForPath(inside.path)));
      expect(await pollUntil(() => acks.length == 2), isTrue);
      expect(acks.last.honored, isTrue);
      expect(
        wired.launcher.calls.map((c) => c.filePath),
        <String>[insideSource],
      );
    });
  });
}

/// [posix] as an absolute path on this platform: unchanged on macOS and
/// Linux, and on the working drive on Windows. There a drive-less `/abs` is
/// rooted but not absolute, and the CXP floor refuses it before the handler
/// sees it.
String _abs(String posix) => p.normalize(p.absolute(posix));
