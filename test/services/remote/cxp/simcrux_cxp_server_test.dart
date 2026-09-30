// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_cxp/crux_cxp.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/services/remote/cxp/simcrux_cxp_server.dart';
import 'package:simcrux/services/remote/cxp/simcrux_name_resolver.dart';

void main() {
  group('buildSimcruxPeerIdentity', () {
    test('uses simcruxCxpProductName as productName', () {
      final id = buildSimcruxPeerIdentity(
        processId: 12345,
        startedAt: DateTime.utc(2026, 5, 24, 12),
      );
      expect(id.productName, simcruxCxpProductName);
    });

    test('builds a peer id from pid + startedAt millis', () {
      final id = buildSimcruxPeerIdentity(
        processId: 7777,
        startedAt: DateTime.utc(2026, 5, 24, 12),
      );
      expect(id.peerId, startsWith('simcrux-7777-'));
      expect(
        id.peerId,
        '$simcruxCxpProductName-7777-'
        '${DateTime.utc(2026, 5, 24, 12).millisecondsSinceEpoch}',
      );
    });

    test('announces the simcrux.debug capability', () {
      final id = buildSimcruxPeerIdentity(
        processId: 1,
        startedAt: DateTime.utc(2026),
      );
      expect(id.capabilities, contains('simcrux.debug'));
    });

    test('two peers built at different times get distinct peer ids', () {
      final a = buildSimcruxPeerIdentity(
        processId: 1,
        startedAt: DateTime.utc(2026),
      );
      final b = buildSimcruxPeerIdentity(
        processId: 1,
        startedAt: DateTime.utc(2026, 1, 2),
      );
      expect(a.peerId, isNot(b.peerId));
    });
  });

  group('SimCruxCxpServer', () {
    test('default port is 54325', () {
      final server = SimCruxCxpServer();
      expect(server.port, defaultSimcruxCxpPort);
      expect(defaultSimcruxCxpPort, 54325);
    });

    test('default nameResolver is a SimCruxNameResolver', () {
      final server = SimCruxCxpServer();
      expect(server.nameResolver, isA<SimCruxNameResolver>());
    });

    test('starts on an OS-picked port (port: 0) and stops cleanly', () async {
      final server = SimCruxCxpServer(
        selfIdentity: buildSimcruxPeerIdentity(processId: 1),
        port: 0,
      );
      await server.start();
      expect(server.isRunning, isTrue);
      expect(server.boundPort, isNotNull);
      expect(server.boundPort, isNot(0));
      expect(server.server, isNotNull);
      await server.stop();
      expect(server.isRunning, isFalse);
      expect(server.boundPort, isNull);
    });

    test('start is idempotent', () async {
      final server = SimCruxCxpServer(
        selfIdentity: buildSimcruxPeerIdentity(processId: 1),
        port: 0,
      );
      await server.start();
      final firstPort = server.boundPort;
      await server.start(); // no-op
      expect(server.boundPort, firstPort);
      await server.stop();
    });

    test('sendTo returns false when server is stopped', () {
      final server = SimCruxCxpServer();
      const message = NotifySelection(
        elements: [ElementId(kind: ElementKind.test, path: 'x/y')],
      );
      expect(server.sendTo('any', message), isFalse);
    });

    test('broadcast on stopped server is a no-op (does not throw)', () {
      final server = SimCruxCxpServer();
      const message = NotifySelection(
        elements: [ElementId(kind: ElementKind.test, path: 'x/y')],
      );
      expect(() => server.broadcast(message), returnsNormally);
    });

    test('inbound / presence on stopped server are empty streams', () async {
      final server = SimCruxCxpServer();
      final inbound = await server.inbound.toList();
      final presence = await server.presence.toList();
      expect(inbound, isEmpty);
      expect(presence, isEmpty);
    });

    test('connectedPeers on stopped server is empty', () {
      final server = SimCruxCxpServer();
      expect(server.connectedPeers, isEmpty);
    });

    test('handshake + sendTo round-trip via LocalCxpClient', () async {
      final server = SimCruxCxpServer(
        selfIdentity: buildSimcruxPeerIdentity(processId: 1),
        port: 0,
      );
      await server.start();

      final client = LocalCxpClient(
        selfIdentity: const PeerIdentity(
          peerId: 'test-client-1',
          productName: 'test',
          productVersion: '0.0.0',
        ),
      );
      await client.connect(
        host: '127.0.0.1',
        port: server.boundPort!,
        token: cxpProcessAuthToken,
      );
      expect(client.isConnected, isTrue);
      expect(client.remotePeer?.productName, simcruxCxpProductName);

      await client.dispose();
      await server.stop();
    });

    // Wire 1.2's peer auth is inherited, not wired: the wrapper passes no
    // token, so `LocalCxpServer`'s default (require the process token) is
    // what SimCrux ships. This pins that default from the product side.
    test('a peer that does not present the token is refused', () async {
      final server = SimCruxCxpServer(
        selfIdentity: buildSimcruxPeerIdentity(processId: 1),
        port: 0,
      );
      await server.start();
      addTearDown(server.stop);

      final client = LocalCxpClient(
        selfIdentity: const PeerIdentity(
          peerId: 'test-client-stranger',
          productName: 'test',
          productVersion: '0.0.0',
        ),
      );
      addTearDown(client.dispose);
      await expectLater(
        client.connect(host: '127.0.0.1', port: server.boundPort!),
        throwsA(
          isA<CxpHandshakeException>().having(
            (e) => e.code,
            'code',
            CxpErrorCode.unauthorized,
          ),
        ),
      );
      expect(server.connectedPeers, isEmpty);
    });

    // The wrapper hands `containment` to `LocalCxpServer`, which screens the
    // path BEFORE dispatch: the refusal ack comes back and [inbound] never
    // carries the request.
    //
    // MUTATION: dropping `containment: containment` from either the
    // `_serverFactory` call in `start` or `_defaultFactory` makes this red.
    test(
      'refuses a file_path outside its roots without dispatching it',
      () async {
        final root = Directory.systemTemp.createTempSync('simcrux_cxp_root_');
        addTearDown(() => root.deleteSync(recursive: true));
        final server = SimCruxCxpServer(
          selfIdentity: buildSimcruxPeerIdentity(processId: 1),
          port: 0,
          containment: CxpPathContainment(roots: () => <String>[root.path]),
        );
        await server.start();
        addTearDown(server.stop);
        final dispatched = <InboundCxpMessage>[];
        final sub = server.inbound.listen(dispatched.add);
        addTearDown(sub.cancel);

        final client = LocalCxpClient(
          selfIdentity: const PeerIdentity(
            peerId: 'test-client-2',
            productName: 'test',
            productVersion: '0.0.0',
          ),
        );
        addTearDown(client.dispose);
        await client.connect(
          host: '127.0.0.1',
          port: server.boundPort!,
          token: cxpProcessAuthToken,
        );
        final ackFuture = client.inbound.firstWhere(
          (m) => m.message is RequestOpenSourceAck,
        );
        // Absolute on this platform: on Windows a drive-less `/etc/shadow`
        // is refused by the floor, before the roots are consulted.
        final shadow = p.normalize(p.absolute('/etc/shadow'));
        client.send(RequestOpenSource(filePath: shadow, line: 1));
        final ack =
            (await ackFuture.timeout(const Duration(seconds: 5))).message
                as RequestOpenSourceAck;
        expect(ack.honored, isFalse);
        expect(ack.reason, contains('outside the directories'));
        expect(ack.reason, isNot(contains(shadow)));
        expect(
          dispatched.where((m) => m.message is RequestOpenSource),
          isEmpty,
        );
      },
    );
  });

  group('CrossProbeEvent', () {
    test('CrossProbeDirection has inbound and outbound', () {
      expect(CrossProbeDirection.values, hasLength(2));
      expect(CrossProbeDirection.values, contains(CrossProbeDirection.inbound));
      expect(
        CrossProbeDirection.values,
        contains(CrossProbeDirection.outbound),
      );
    });

    test('constructs with required fields', () {
      final event = CrossProbeEvent(
        timestamp: DateTime.utc(2026),
        direction: CrossProbeDirection.outbound,
        kind: CxpMessageKind.notifySelection,
        peerId: 'p1',
      );
      expect(event.timestamp, DateTime.utc(2026));
      expect(event.kind, 'notify_selection');
      expect(event.peerId, 'p1');
      expect(event.summary, isNull);
    });
  });
}
