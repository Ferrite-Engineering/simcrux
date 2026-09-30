// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'dart:io';

import 'package:crux_cxp/crux_cxp.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/services/remote/cxp/simcrux_cxp_discovery.dart';
import 'package:simcrux/services/remote/cxp/simcrux_cxp_server.dart';

import '../../../support/poll_until.dart';

void main() {
  group('SimCruxCxpDiscoveryService', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('simcrux_cxp_disc_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('start writes a manifest, stop removes it', () async {
      final service = SimCruxCxpDiscoveryService(
        manifestDirectory: tempDir.path,
        scanInterval: const Duration(milliseconds: 200),
      );
      // Anchor to THIS live process's pid: the crux_cxp 0.4.2 liveness prune
      // reaps a manifest whose pid reads dead, and SimCrux's discovery does not
      // wire the self-exemption (the identity isn't known at CxpDiscovery
      // construction), so a synthetic dead pid would reap the self-manifest
      // mid-test. Mirrors WaveCrux's server test (CXP Cross-Probe Increment).
      final identity = buildSimcruxPeerIdentity(
        processId: pid,
        startedAt: DateTime.utc(2026),
      );
      await service.start(
        identity: identity,
        host: '127.0.0.1',
        port: 54325,
        server: NoopCxpServer(selfIdentity: identity),
      );

      // Wait for the watcher to do its initial scan and pick up our
      // own manifest.
      final manifestPath = p.join(tempDir.path, '${identity.peerId}.json');
      final wrote = await pollUntil(() => File(manifestPath).existsSync());
      expect(wrote, isTrue, reason: 'expected the self-manifest to appear');

      await service.stop();
      expect(File(manifestPath).existsSync(), isFalse);
    });

    test('exposes empty dial failures while stopped', () async {
      final service = SimCruxCxpDiscoveryService(
        manifestDirectory: tempDir.path,
        scanInterval: const Duration(milliseconds: 200),
      );
      expect(service.lastDialFailures, isEmpty);
      // The stopped service returns an already-closed empty stream.
      expect(await service.dialFailures.isEmpty, isTrue);
    });

    test(
      'lastDialFailures records a peer whose dial is refused',
      () async {
        final service = SimCruxCxpDiscoveryService(
          manifestDirectory: tempDir.path,
          scanInterval: const Duration(milliseconds: 200),
        );
        final identity = buildSimcruxPeerIdentity(processId: 4242);
        await service.start(
          identity: identity,
          host: '127.0.0.1',
          port: 54325,
          server: NoopCxpServer(selfIdentity: identity),
        );
        addTearDown(service.stop);

        // Publish a foreign manifest pointing at a closed port; the
        // connector dials it and the refusal lands in lastDialFailures.
        final writer = CxpManifestWriter(manifestDirectory: tempDir.path);
        const foreign = PeerIdentity(
          peerId: 'wavecrux-unreachable-1',
          productName: 'wavecrux',
          productVersion: '0.1.0',
        );
        await writer.write(identity: foreign, host: '127.0.0.1', port: 1);

        final recorded = await pollUntil(
          () => service.lastDialFailures.containsKey('wavecrux-unreachable-1'),
        );
        expect(recorded, isTrue, reason: 'expected a recorded dial failure');
        expect(
          service.lastDialFailures['wavecrux-unreachable-1']!.port,
          1,
        );
      },
    );

    test(
      'discovery emits added event for an externally-written peer manifest',
      () async {
        final service = SimCruxCxpDiscoveryService(
          manifestDirectory: tempDir.path,
          scanInterval: const Duration(milliseconds: 200),
        );
        final selfId = buildSimcruxPeerIdentity(processId: 1);
        await service.start(
          identity: selfId,
          host: '127.0.0.1',
          port: 54325,
          server: NoopCxpServer(selfIdentity: selfId),
        );
        addTearDown(service.stop);

        // Subscribe to events first; we'll inject a manifest file for
        // a different peer and assert we see the added event.
        final events = <CxpDiscoveryEvent>[];
        final sub = service.discovery.events.listen(events.add);
        addTearDown(sub.cancel);

        // Write a fake "wavecrux" peer manifest into the watched
        // directory. Use a fresh writer so the path management is
        // independent of the service's own writer.
        final fakeWriter = CxpManifestWriter(manifestDirectory: tempDir.path);
        // Anchor the foreign manifest's pid to THIS live process so the
        // crux_cxp 0.4.2 liveness prune (which reaps manifests whose pid reads
        // dead) does not reap it mid-test (CXP Cross-Probe Increment gotcha).
        final wavePeerId = 'wavecrux-$pid-100';
        final fakeIdentity = PeerIdentity(
          peerId: wavePeerId,
          productName: 'wavecrux',
          productVersion: '0.1.0',
        );
        await fakeWriter.write(
          identity: fakeIdentity,
          host: '127.0.0.1',
          port: 54322,
        );

        // Wait for the scan tick that picks up the new manifest.
        List<CxpDiscoveryEvent> addedEvents() => events
            .where(
              (e) => e.added && e.manifest.identity.peerId == wavePeerId,
            )
            .toList();
        final added = await pollUntil(() => addedEvents().length == 1);
        expect(added, isTrue, reason: 'expected exactly one added event');
        expect(addedEvents().single.manifest.identity.productName, 'wavecrux');
        expect(addedEvents().single.manifest.port, 54322);

        // Remove and assert we see the disappear.
        await fakeWriter.remove();
        List<CxpDiscoveryEvent> removedEvents() => events
            .where(
              (e) => !e.added && e.manifest.identity.peerId == wavePeerId,
            )
            .toList();
        final removed = await pollUntil(() => removedEvents().length == 1);
        expect(removed, isTrue, reason: 'expected exactly one removed event');
      },
    );

    test(
      'SimCrux and a WaveCrux-style peer sharing one '
      'manifest directory end up MUTUALLY CONNECTED',
      () async {
        // SimCrux side: real server + discovery service (which now runs
        // the peer connector).
        final simServer = SimCruxCxpServer(port: 0);
        await simServer.start();
        addTearDown(simServer.stop);
        final simDiscovery = SimCruxCxpDiscoveryService(
          manifestDirectory: tempDir.path,
          scanInterval: const Duration(milliseconds: 100),
        );
        await simDiscovery.start(
          identity: simServer.selfIdentity,
          host: '127.0.0.1',
          port: simServer.boundPort!,
          server: simServer.server!,
        );
        addTearDown(simDiscovery.stop);

        // "WaveCrux" side: raw shared-package primitives, same directory.
        // Real-pid anchor so the crux_cxp 0.4.2 liveness prune keeps this
        // foreign manifest discoverable for the test's lifetime.
        final waveId = PeerIdentity(
          peerId: 'wavecrux-$pid-1',
          productName: 'wavecrux',
          productVersion: '0.3.0',
        );
        final waveServer = LocalCxpServer(selfIdentity: waveId);
        await waveServer.start();
        addTearDown(waveServer.stop);
        final waveWriter = CxpManifestWriter(
          manifestDirectory: tempDir.path,
          heartbeatInterval: const Duration(milliseconds: 100),
        );
        addTearDown(waveWriter.remove);
        await waveWriter.write(
          identity: waveId,
          host: '127.0.0.1',
          port: waveServer.boundPort!,
        );
        final waveDiscovery = CxpDiscovery(
          manifestDirectory: tempDir.path,
          scanInterval: const Duration(milliseconds: 100),
        );
        addTearDown(waveDiscovery.stop);
        final waveConnector = CxpPeerConnector(
          selfIdentity: waveId,
          discovery: waveDiscovery,
          server: waveServer,
          retryInterval: const Duration(milliseconds: 100),
        );
        addTearDown(waveConnector.stop);
        await waveDiscovery.start();
        waveConnector.start();

        // Pre-fix: discovery surfaced the manifests but no socket was
        // ever opened, so BOTH connectedPeers lists stayed empty and the
        // Cross-probe menu / Debug-in-WaveCrux flow (which gate on
        // SimCrux's server.connectedPeers) were dead forever.
        final mutual = await pollUntil(
          () =>
              simServer.connectedPeers.any((p) => p.peerId == waveId.peerId) &&
              waveServer.connectedPeers.any(
                (p) => p.peerId == simServer.selfIdentity.peerId,
              ),
        );
        expect(
          mutual,
          isTrue,
          reason:
              'both servers must see the other CONNECTED via the '
              'symmetric peer connectors',
        );

        // SimCrux discovers the wavecrux manifest at the manifest level
        // too (the menu intersects discovered ∩ connected). Bounded poll,
        // not an instant assertion: since crux_cxp's attachLinkedPeer change,
        // `connectedPeers` can converge from EITHER side's own dial-out
        // (each peer connector attaches to its OWN server on handshake),
        // so `mutual` above can resolve before SimCrux's own discovery
        // scan has independently found wave's manifest.
        final simDiscovered = await pollUntil(
          () => simDiscovery.discovery.peers.any(
            (m) => m.identity.peerId == waveId.peerId,
          ),
        );
        expect(
          simDiscovered,
          isTrue,
          reason:
              "expected SimCrux's own discovery scan to find wave's "
              'manifest',
        );
      },
    );

    test(
      'end-to-end product traffic over the connector-dialed link reaches '
      "the PEER's own server.inbound, and its ack routes back to "
      'SimCrux.server.inbound — presence (mutual connect) alone proves '
      'nothing about this; mirrors crux_cxp peer_connectivity_test.dart '
      "'end-to-end product traffic' and crux_cxp f40a742",
      () async {
        final simServer = SimCruxCxpServer(port: 0);
        await simServer.start();
        addTearDown(simServer.stop);
        final simDiscovery = SimCruxCxpDiscoveryService(
          manifestDirectory: tempDir.path,
          scanInterval: const Duration(milliseconds: 100),
        );
        await simDiscovery.start(
          identity: simServer.selfIdentity,
          host: '127.0.0.1',
          port: simServer.boundPort!,
          server: simServer.server!,
        );
        addTearDown(simDiscovery.stop);

        const waveId = PeerIdentity(
          peerId: 'wavecrux-e2e-1',
          productName: 'wavecrux',
          productVersion: '0.3.0',
        );
        final waveServer = LocalCxpServer(selfIdentity: waveId);
        await waveServer.start();
        addTearDown(waveServer.stop);
        final waveWriter = CxpManifestWriter(
          manifestDirectory: tempDir.path,
          heartbeatInterval: const Duration(milliseconds: 100),
        );
        addTearDown(waveWriter.remove);
        await waveWriter.write(
          identity: waveId,
          host: '127.0.0.1',
          port: waveServer.boundPort!,
        );
        final waveDiscovery = CxpDiscovery(
          manifestDirectory: tempDir.path,
          scanInterval: const Duration(milliseconds: 100),
        );
        addTearDown(waveDiscovery.stop);
        final waveConnector = CxpPeerConnector(
          selfIdentity: waveId,
          discovery: waveDiscovery,
          server: waveServer,
          retryInterval: const Duration(milliseconds: 100),
        );
        addTearDown(waveConnector.stop);
        await waveDiscovery.start();
        waveConnector.start();

        final mutual = await pollUntil(
          () =>
              simServer.connectedPeers.any((p) => p.peerId == waveId.peerId) &&
              waveServer.connectedPeers.any(
                (p) => p.peerId == simServer.selfIdentity.peerId,
              ),
        );
        expect(mutual, isTrue, reason: 'both sides must be mutually connected');

        // Listeners attach BEFORE the send so the broadcast inbound
        // streams cannot miss the frame.
        final waveInbound = <InboundCxpMessage>[];
        final waveSub = waveServer.inbound.listen(waveInbound.add);
        addTearDown(waveSub.cancel);

        // SimCrux dispatches a RequestHighlight — the same call the
        // Debug-in-WaveCrux dispatcher makes. The lie this guards against:
        // `delivered == true` alone proves nothing about receipt.
        const element = ElementId(
          kind: ElementKind.source,
          path: '/abs/run/dump.vcd',
        );
        final delivered = simServer.sendTo(
          waveId.peerId,
          const RequestHighlight(element: element),
        );
        expect(delivered, isTrue, reason: 'sendTo must report delivery');

        final gotRequest = await pollUntil(
          () => waveInbound.any((m) => m.message is RequestHighlight),
        );
        expect(
          gotRequest,
          isTrue,
          reason:
              "the request must reach the peer's own server.inbound over "
              'the connector-dialed link, not merely report delivered:true',
        );
        final request = waveInbound.firstWhere(
          (m) => m.message is RequestHighlight,
        );
        expect(request.from.peerId, simServer.selfIdentity.peerId);
        expect((request.message as RequestHighlight).element, element);

        // Peer acks back over the same link; SimCrux must receive it on
        // its own server.inbound (requires simDiscovery's connector to
        // route its outbound link — the SimCrux fix under test).
        final simInbound = <InboundCxpMessage>[];
        final simSub = simServer.inbound.listen(simInbound.add);
        addTearDown(simSub.cancel);
        waveServer.sendTo(
          simServer.selfIdentity.peerId,
          RequestHighlightAck(
            inReplyTo: request.envelope.messageId,
            honored: true,
          ),
        );
        final gotAck = await pollUntil(
          () => simInbound.any((m) => m.message is RequestHighlightAck),
        );
        expect(
          gotAck,
          isTrue,
          reason:
              "the peer's ack must route back into SimCrux's own "
              'server.inbound over the link SimCrux dialed out on',
        );
      },
    );

    test('start is idempotent', () async {
      final service = SimCruxCxpDiscoveryService(
        manifestDirectory: tempDir.path,
        scanInterval: const Duration(milliseconds: 200),
      );
      final identity = buildSimcruxPeerIdentity(processId: 1);
      final noopServer = NoopCxpServer(selfIdentity: identity);
      await service.start(
        identity: identity,
        host: '127.0.0.1',
        port: 54325,
        server: noopServer,
      );
      // Second start is a no-op — must not throw, must not crash on
      // the watcher's "already running" guard.
      await service.start(
        identity: identity,
        host: '127.0.0.1',
        port: 54325,
        server: noopServer,
      );
      expect(service.isRunning, isTrue);
      await service.stop();
    });
  });
}
