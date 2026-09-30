// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'dart:io';

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/remote/providers/cross_probe_events_provider.dart';
import 'package:simcrux/features/remote/providers/cxp_discovery_provider.dart';
import 'package:simcrux/features/remote/providers/cxp_server_provider.dart';
import 'package:simcrux/features/remote/providers/notify_selection_emitter.dart';
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

/// Peer id of the test client. Shared so the subscription-registration
/// poll and the client identity cannot drift apart.
const String kEmitterClientPeerId = 'test-emitter-client';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<
    ({
      ProviderContainer container,
      LocalCxpClient client,
      SimCruxCxpServer server,
    })
  >
  wireClient() async {
    final container = ProviderContainer(
      overrides: <Override>[
        ...answeredTelemetryOverrides(),
        cxpServerFactoryProvider.overrideWithValue(
          ({required selfIdentity, required port}) => SimCruxCxpServer(
            selfIdentity: selfIdentity,
            port: 0,
          ),
        ),
      ],
    );
    await container.read(appSettingsProvider.future);
    final server = await container.read(cxpServerProvider.future);
    expect(server, isNotNull);

    final client = LocalCxpClient(
      selfIdentity: const PeerIdentity(
        peerId: kEmitterClientPeerId,
        productName: 'test',
        productVersion: '0.0.0',
      ),
    );
    await client.connect(
      host: '127.0.0.1',
      port: server!.boundPort!,
      token: cxpProcessAuthToken,
    );
    client.send(
      const Subscribe(
        subscriptions: <CxpSubscription>[
          CxpSubscription(messageKind: CxpMessageKind.notifySelection),
        ],
      ),
    );
    // The Subscribe travels over a real socket and registers
    // asynchronously. A broadcast issued before it lands reaches no
    // subscriber and is dropped silently, so wait on the registration
    // itself rather than on a fixed grace period whose adequacy
    // depends on machine speed and concurrent load.
    final subscribed = await pollUntil(
      () =>
          server.server!.debugSubscriptionsOf(kEmitterClientPeerId).isNotEmpty,
    );
    expect(
      subscribed,
      isTrue,
      reason: 'the subscription must register before any broadcast',
    );
    return (container: container, client: client, server: server);
  }

  group('NotifySelectionEmitter', () {
    test('broadcasts ElementKind.test on test selection change', () async {
      final wired = await wireClient();
      addTearDown(() async {
        await wired.client.dispose();
        wired.container.dispose();
      });

      // Anchor the emitter.
      wired.container.read(notifySelectionEmitterProvider);

      final received = wired.client.inbound.firstWhere(
        (m) => m.message is NotifySelection,
      );
      wired.container
          .read(selectedTestIdProvider.notifier)
          .select('cpu_unit/test_alu_basic');
      final inbound = await received.timeout(const Duration(seconds: 2));
      final msg = inbound.message as NotifySelection;
      expect(msg.elements.single.kind, ElementKind.test);
      expect(msg.elements.single.path, 'cpu_unit/test_alu_basic');
      expect(msg.displayName, 'cpu_unit/test_alu_basic');
    });

    test(
      'broadcasts ElementKind.source on explicit source selection',
      () async {
        final wired = await wireClient();
        addTearDown(() async {
          await wired.client.dispose();
          wired.container.dispose();
        });

        wired.container.read(notifySelectionEmitterProvider);

        final received = wired.client.inbound.firstWhere(
          (m) => m.message is NotifySelection,
        );
        wired.container
            .read(explicitSourceSelectionProvider.notifier)
            .select('/abs/rtl/alu.sv');
        final inbound = await received.timeout(const Duration(seconds: 2));
        final msg = inbound.message as NotifySelection;
        expect(msg.elements.single.kind, ElementKind.source);
        expect(msg.elements.single.path, '/abs/rtl/alu.sv');
      },
    );

    test(
      'records an outbound event in the cross-probe events buffer',
      () async {
        final wired = await wireClient();
        addTearDown(() async {
          await wired.client.dispose();
          wired.container.dispose();
        });

        wired.container.read(notifySelectionEmitterProvider);

        // Pre-condition: no events yet (the inbound stream listener has
        // attached but no message has been received).
        var events = wired.container.read(crossProbeEventsProvider);
        expect(events, isEmpty);

        wired.container
            .read(selectedTestIdProvider.notifier)
            .select('alpha/beta');
        // Wait for the broadcast to fan out and the listener to record.
        final recorded = await pollUntil(
          () => wired.container.read(crossProbeEventsProvider).isNotEmpty,
        );
        expect(recorded, isTrue, reason: 'expected an outbound event');
        events = wired.container.read(crossProbeEventsProvider);
        final outbound = events
            .where((e) => e.direction == CrossProbeDirection.outbound)
            .toList();
        expect(outbound, hasLength(1));
        expect(outbound.single.kind, CxpMessageKind.notifySelection);
        expect(outbound.single.summary, 'alpha/beta');
      },
    );

    test('does not emit when CXP server is disabled', () async {
      final container = ProviderContainer(
        overrides: <Override>[
          ...answeredTelemetryOverrides(),
          cxpServerFactoryProvider.overrideWithValue(
            ({required selfIdentity, required port}) => SimCruxCxpServer(
              selfIdentity: selfIdentity,
              port: 0,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(appSettingsProvider.future);
      await container
          .read(appSettingsProvider.notifier)
          .updateCxpServerEnabled(enabled: false);
      await container.read(cxpServerProvider.future);

      // Anchor the emitter.
      container.read(notifySelectionEmitterProvider);

      // Change selection — no broadcast happens because there is no
      // running server.
      container.read(selectedTestIdProvider.notifier).select('alpha/beta');
      // An absence assertion, and the absence is decided synchronously:
      // the emitter's broadcast path reads `cxpServerProvider`, finds no
      // server and returns before recording anything. There is no
      // observable transition to poll for, so a short settle is the
      // right shape here — it only has to outlast a microtask drain, not
      // a socket round trip.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final events = container.read(crossProbeEventsProvider);
      expect(events, isEmpty);
    });

    test("broadcasts the ACTIVE tab container's selection changes when "
        'a workspace is mounted (per-tab providers never touch the '
        'root instance)', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'simcrux_emitter_ws_',
      );
      late final ProviderContainer container;
      final managersCreated = <WorkspaceContainerManagers>[];
      container = ProviderContainer(
        overrides: <Override>[
          ...answeredTelemetryOverrides(),
          cxpServerFactoryProvider.overrideWithValue(
            ({required selfIdentity, required port}) => SimCruxCxpServer(
              selfIdentity: selfIdentity,
              port: 0,
            ),
          ),
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

      await container.read(appSettingsProvider.future);
      final server = await container.read(cxpServerProvider.future);
      expect(server, isNotNull);

      // Open one tab (becomes active) BEFORE anchoring the emitter so
      // attach() finds the active tab immediately.
      await container.read(workspaceProvider.future);
      final tabId = await container
          .read(workspaceProvider.notifier)
          .openTab(
            displayName: 'a',
            payload: SimcruxTabPayload(configPath: '/p/a.yaml'),
          );
      container.read(notifySelectionEmitterProvider);

      final client = LocalCxpClient(
        selfIdentity: const PeerIdentity(
          peerId: kEmitterClientPeerId,
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
      client.send(
        const Subscribe(
          subscriptions: <CxpSubscription>[
            CxpSubscription(messageKind: CxpMessageKind.notifySelection),
          ],
        ),
      );
      final subscribed = await pollUntil(
        () => server.server!
            .debugSubscriptionsOf(kEmitterClientPeerId)
            .isNotEmpty,
      );
      expect(
        subscribed,
        isTrue,
        reason: 'the subscription must register before any broadcast',
      );

      // Selecting inside the ACTIVE tab container broadcasts — this is
      // the real app path (root selectedTestIdProvider stays dormant).
      final received = client.inbound.firstWhere(
        (m) => m.message is NotifySelection,
      );
      final managers = container.read(workspaceContainerManagersProvider);
      managers.tabs
          .containerFor(tabId)
          .read(selectedTestIdProvider.notifier)
          .select('cpu_unit/test_alu_basic');
      final inbound = await received.timeout(const Duration(seconds: 2));
      final msg = inbound.message as NotifySelection;
      expect(msg.elements.single.kind, ElementKind.test);
      expect(msg.elements.single.path, 'cpu_unit/test_alu_basic');
    });

    test(
      'does not auto-broadcast when broadcastSelectionOnCrossProbe is off',
      () async {
        // Persist the setting OFF before anything reads settings, so the
        // server starts once with the gate already closed. (Toggling the
        // setting at runtime would rebuild cxpServerProvider — it watches the
        // whole AppSettings — and restart the server, dropping this client;
        // that server-restart-on-settings-change is the same pre-existing
        // behaviour the request-attention toggle triggers, and is not what
        // this test is about.)
        SharedPreferences.setMockInitialValues(<String, Object>{
          'simcrux.broadcastSelectionOnCrossProbe': false,
        });
        final wired = await wireClient();
        addTearDown(() async {
          await wired.client.dispose();
          wired.container.dispose();
        });
        expect(
          wired.container
              .read(appSettingsProvider)
              .value!
              .broadcastSelectionOnCrossProbe,
          isFalse,
        );

        wired.container.read(notifySelectionEmitterProvider);

        final received = <CxpClientInbound>[];
        final sub = wired.client.inbound
            .where((m) => m.message is NotifySelection)
            .listen(received.add);
        addTearDown(sub.cancel);

        // A selection change must NOT reach the wire while the setting is off.
        wired.container
            .read(selectedTestIdProvider.notifier)
            .select('cpu_unit/test_alu_basic');

        // Absence assertion: the emitter's broadcast path reads the setting
        // and returns before touching the server, so no observable transition
        // exists to poll for — a short settle outlasting a microtask drain is
        // the right shape.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(received, isEmpty);
        expect(wired.container.read(crossProbeEventsProvider), isEmpty);
      },
    );

    test(
      'does not re-emit when the selection toggles to the same value',
      () async {
        final wired = await wireClient();
        addTearDown(() async {
          await wired.client.dispose();
          wired.container.dispose();
        });

        wired.container.read(notifySelectionEmitterProvider);

        final received = <CxpClientInbound>[];
        final sub = wired.client.inbound
            .where((m) => m.message is NotifySelection)
            .listen(received.add);
        addTearDown(sub.cancel);

        // Set to the same value back-to-back.
        wired.container
            .read(selectedTestIdProvider.notifier)
            .select('alpha/beta');
        wired.container
            .read(selectedTestIdProvider.notifier)
            .select('alpha/beta');
        final settled = await pollUntil(() => received.length == 1);
        expect(settled, isTrue, reason: 'expected exactly one broadcast');
        expect(received, hasLength(1));
      },
    );

    test(
      'broadcasts reach a real connector-linked peer that never sent a '
      'manual Subscribe — the connector auto-subscribes every link on '
      'handshake (crux_cxp fb8be19); presence alone proves nothing about this',
      () async {
        final manifestDir = await Directory.systemTemp.createTemp(
          'simcrux_emitter_manifest_e2e_',
        );
        final container = ProviderContainer(
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
          ],
        );
        addTearDown(() {
          container.dispose();
          deleteManifestDir(manifestDir);
        });

        await container.read(appSettingsProvider.future);
        final server = await container.read(cxpServerProvider.future);
        expect(server, isNotNull);
        await container.read(cxpDiscoveryProvider.future);
        container.read(notifySelectionEmitterProvider);

        const waveId = PeerIdentity(
          peerId: 'wavecrux-emitter-e2e-1',
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

        // Mutual *presence* is not mutual *readiness*, and the gap between
        // them is where this test used to lose the race under parallel load.
        // Both sides register a peer as connected the moment their own
        // connector attaches the link — `attachLinkedPeer` is a local call
        // with no wire round trip — while the peer's auto-`Subscribe`
        // (CxpPeerConnector._onLinkEvent) is still travelling the socket.
        // `LocalCxpServer.broadcast` consults the recorded subscription set
        // and drops the frame for any peer whose set is still empty, and
        // notify_selection is fire-and-forget: a frame dropped in that
        // window is never retried, so a broadcast issued there makes the
        // wait below time out with certainty rather than merely slowly.
        // Gate on the registration itself — the same rule wireClient
        // follows for its manual Subscribe.
        final subscribed = await pollUntil(
          () => server!.server!.debugSubscriptionsOf(waveId.peerId).isNotEmpty,
        );
        expect(
          subscribed,
          isTrue,
          reason:
              "the connector's auto-Subscribe must be recorded on this "
              'server before any broadcast, or the frame is dropped',
        );

        container
            .read(selectedTestIdProvider.notifier)
            .select('cpu_unit/test_alu_basic');

        final gotIt = await pollUntil(
          () => peer.received.any((m) => m.message is NotifySelection),
        );
        expect(
          gotIt,
          isTrue,
          reason:
              "the peer's own server.inbound must receive the "
              'broadcast without ever sending a manual Subscribe — the '
              'connector announced it automatically on handshake',
        );
        final notify =
            peer.received
                    .firstWhere((m) => m.message is NotifySelection)
                    .message
                as NotifySelection;
        expect(notify.elements.single.kind, ElementKind.test);
        expect(notify.elements.single.path, 'cpu_unit/test_alu_basic');
      },
    );
  });
}
