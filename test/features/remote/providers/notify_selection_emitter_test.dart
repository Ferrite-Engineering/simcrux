// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'dart:io';

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/remote/providers/notify_selection_emitter.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/container_managers.dart';
import 'package:simcrux/features/workspace/providers/simcrux_tab_overrides.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/services/simcrux_workspace_codec.dart';

import '../../../support/cxp_fake_peer.dart';
import '../../../support/cxp_runtime_harness.dart';
import '../../../support/poll_until.dart';

/// Peer id of the test client. Shared so the subscription-registration
/// poll and the client identity cannot drift apart.
const String kEmitterClientPeerId = 'test-emitter-client';

void main() {
  late Directory manifests;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    manifests = cxpTestManifestDirectory();
  });

  Future<LocalCxpClient> connectSubscribedClient(
    CruxCxpRuntime runtime,
    CapturedCxpServer captured,
  ) async {
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
      port: runtime.boundPort!,
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
      () => captured.server!
          .debugSubscriptionsOf(kEmitterClientPeerId)
          .isNotEmpty,
    );
    expect(
      subscribed,
      isTrue,
      reason: 'the subscription must register before any broadcast',
    );
    return client;
  }

  Future<({ProviderContainer container, LocalCxpClient client})> wireClient({
    bool broadcastSelection = true,
  }) async {
    final captured = CapturedCxpServer();
    final container = simcruxCxpRuntimeContainer(
      manifestDirectory: manifests,
      broadcastSelection: broadcastSelection,
      capture: captured,
    );
    final runtime = await runningCxpRuntime(container);
    final client = await connectSubscribedClient(runtime, captured);
    return (container: container, client: client);
  }

  group('NotifySelectionEmitter', () {
    test('broadcasts ElementKind.test on test selection change', () async {
      final wired = await wireClient();

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

    test('the runtime records the broadcast in the cross-probe event log, '
        'so the emitter records nothing itself', () async {
      final wired = await wireClient();

      wired.container.read(notifySelectionEmitterProvider);

      // Pre-condition: no selection event yet.
      expect(
        wired.container
            .read(cruxCxpEventLogProvider)
            .where((e) => e.kind == CrossProbeEventKind.selectionSent),
        isEmpty,
      );

      wired.container
          .read(selectedTestIdProvider.notifier)
          .select('alpha/beta');
      // Wait for the broadcast to fan out and the log to record it.
      final recorded = await pollUntil(
        () => wired.container
            .read(cruxCxpEventLogProvider)
            .any((e) => e.kind == CrossProbeEventKind.selectionSent),
      );
      expect(recorded, isTrue, reason: 'expected an outbound event');
      final outbound = wired.container
          .read(cruxCxpEventLogProvider)
          .where((e) => e.direction == CrossProbeEventDirection.outbound)
          .where((e) => e.kind == CrossProbeEventKind.selectionSent)
          .toList();
      expect(outbound, hasLength(1));
      expect(outbound.single.messageKind, CxpMessageKind.notifySelection);
      expect(outbound.single.summary, 'alpha/beta');
    });

    test('does not emit when CXP server is disabled', () async {
      final container = simcruxCxpRuntimeContainer(
        manifestDirectory: manifests,
        enabled: false,
      );
      expect(await container.read(cruxCxpRuntimeProvider.future), isNull);

      // Anchor the emitter.
      container.read(notifySelectionEmitterProvider);

      // Change selection: no broadcast happens because there is no running
      // server.
      container.read(selectedTestIdProvider.notifier).select('alpha/beta');
      // An absence assertion, and the absence is decided synchronously: the
      // shared broadcast finds no runtime and returns before recording
      // anything. There is no observable transition to poll for, so a short
      // settle is the right shape here: it only has to outlast a microtask
      // drain, not a socket round trip.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(container.read(cruxCxpEventLogProvider), isEmpty);
    });

    test("broadcasts the ACTIVE tab container's selection changes when "
        'a workspace is mounted (per-tab providers never touch the '
        'root instance)', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'simcrux_emitter_ws_',
      );
      final managersCreated = <WorkspaceContainerManagers>[];
      final captured = CapturedCxpServer();
      late final ProviderContainer container;
      container = simcruxCxpRuntimeContainer(
        manifestDirectory: manifests,
        capture: captured,
        extra: <Override>[
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
        if (tempDir.existsSync()) await tempDir.delete(recursive: true);
      });

      final runtime = await runningCxpRuntime(container);

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

      final client = await connectSubscribedClient(runtime, captured);

      // Selecting inside the ACTIVE tab container broadcasts: this is
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

    test('after a tab switch, a selection in the new tab is broadcast and one '
        'in the old tab is not, with the emitter read once', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'simcrux_emitter_switch_',
      );
      final managersCreated = <WorkspaceContainerManagers>[];
      final captured = CapturedCxpServer();
      late final ProviderContainer container;
      container = simcruxCxpRuntimeContainer(
        manifestDirectory: manifests,
        capture: captured,
        extra: <Override>[
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
        if (tempDir.existsSync()) await tempDir.delete(recursive: true);
      });

      final runtime = await runningCxpRuntime(container);
      await container.read(workspaceProvider.future);
      final tabA = await container
          .read(workspaceProvider.notifier)
          .openTab(
            displayName: 'a',
            payload: SimcruxTabPayload(configPath: '/p/a.yaml'),
          );
      // Launch order: one read of the emitter, tab A active.
      container.read(notifySelectionEmitterProvider);
      final tabB = await container
          .read(workspaceProvider.notifier)
          .openTab(
            displayName: 'b',
            payload: SimcruxTabPayload(configPath: '/p/b.yaml'),
          );
      // Let the container deliver the switch, as the frames between a click
      // and the next selection do.
      await Future<void>.delayed(Duration.zero);

      final client = await connectSubscribedClient(runtime, captured);
      final received = <NotifySelection>[];
      final sub = client.inbound
          .where((m) => m.message is NotifySelection)
          .listen((m) => received.add(m.message as NotifySelection));
      addTearDown(sub.cancel);

      final managers = container.read(workspaceContainerManagersProvider);
      managers.tabs
          .containerFor(tabA)
          .read(selectedTestIdProvider.notifier)
          .select('cpu_unit/old_tab_test');
      managers.tabs
          .containerFor(tabB)
          .read(selectedTestIdProvider.notifier)
          .select('cpu_unit/new_tab_test');
      final arrived = await pollUntil(() => received.isNotEmpty);
      expect(arrived, isTrue, reason: 'the new tab must broadcast');
      // The old tab's selection was made first; had it been broadcast it would
      // have arrived before the new tab's.
      expect(received.map((m) => m.elements.single.path).toList(), [
        'cpu_unit/new_tab_test',
      ]);
    });

    test(
      'does not auto-broadcast when "Broadcast selection automatically" is '
      'off',
      () async {
        final wired = await wireClient(broadcastSelection: false);
        expect(
          wired.container.read(cruxCxpSettingsProvider).broadcastSelection,
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

        // Absence assertion: the shared broadcast reads the setting and
        // returns before touching the runtime, so no observable transition
        // exists to poll for: a short settle outlasting a microtask drain is
        // the right shape.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(received, isEmpty);
        expect(
          wired.container
              .read(cruxCxpEventLogProvider)
              .where((e) => e.kind == CrossProbeEventKind.selectionSent),
          isEmpty,
        );
      },
    );

    test(
      'does not re-emit when the selection toggles to the same value',
      () async {
        final wired = await wireClient();

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
        final captured = CapturedCxpServer();
        final container = simcruxCxpRuntimeContainer(
          manifestDirectory: manifests,
          capture: captured,
        );
        final runtime = await runningCxpRuntime(container);
        container.read(notifySelectionEmitterProvider);

        const waveId = PeerIdentity(
          peerId: 'wavecrux-emitter-e2e-1',
          productName: 'wavecrux',
          productVersion: '0.3.0',
        );
        final peer = await CxpFakePeer.start(
          identity: waveId,
          manifestDirectory: manifests.path,
        );
        addTearDown(peer.stop);

        final mutual = await pollUntil(
          () =>
              runtime.peers.any((p) => p.peerId == waveId.peerId) &&
              peer.isConnectedTo(runtime.selfIdentity.peerId),
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
        // Gate on the registration itself.
        final subscribed = await pollUntil(
          () => captured.server!.debugSubscriptionsOf(waveId.peerId).isNotEmpty,
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
