// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_cxp/crux_cxp.dart';

/// A full connector-linked CXP peer stack for tests: its own server,
/// manifest writer, discovery watcher, and a [CxpPeerConnector] wired
/// with `server:` so link traffic routes into [server]'s own `inbound`.
///
/// Standing up this stack (rather than a raw [LocalCxpClient] dialing
/// directly into SimCrux's server) is the point: a raw client's
/// `.inbound` stream is populated by the socket read loop regardless of
/// whether SimCrux's OWN connector correctly routes connector-dialed
/// traffic into its product-level dispatch stream. [received] is that
/// peer's genuine product-level stream — the same shape every real Crux
/// product's request handler subscribes to — so asserting against it
/// proves receipt, not merely that `sendTo`/`broadcast` returned `true`.
/// Mirrors crux_cxp's `peer_connectivity_test.dart` "end-to-end product
/// traffic" case and crux-shared commit b9702df.
class CxpFakePeer {
  CxpFakePeer._({
    required this.identity,
    required this.server,
    required this.writer,
    required this.discovery,
    required this.connector,
  });

  /// The peer's identity as announced in its manifest and handshake.
  final PeerIdentity identity;

  /// The peer's own CXP server — the production-shaped dispatch target.
  final LocalCxpServer server;

  /// Writer holding the peer's manifest file.
  final CxpManifestWriter writer;

  /// Watcher scanning the shared manifest directory.
  final CxpDiscovery discovery;

  /// Dials every discovered non-self manifest and routes link traffic
  /// into [server].
  final CxpPeerConnector connector;

  /// Every message the peer's own [server].inbound has received, in
  /// order. Assert against this, not a raw client stream.
  final List<InboundCxpMessage> received = <InboundCxpMessage>[];

  StreamSubscription<InboundCxpMessage>? _sub;

  /// Starts a full peer stack rooted at [manifestDirectory] — the same
  /// directory SimCrux's own discovery service must be pointed at for
  /// the two to find each other.
  static Future<CxpFakePeer> start({
    required PeerIdentity identity,
    required String manifestDirectory,
    Duration scanInterval = const Duration(milliseconds: 30),
  }) async {
    final server = LocalCxpServer(selfIdentity: identity);
    await server.start();
    final writer = CxpManifestWriter(
      manifestDirectory: manifestDirectory,
      heartbeatInterval: scanInterval,
    );
    await writer.write(
      identity: identity,
      host: '127.0.0.1',
      port: server.boundPort!,
    );
    final discovery = CxpDiscovery(
      manifestDirectory: manifestDirectory,
      scanInterval: scanInterval,
    );
    await discovery.start();
    final connector = CxpPeerConnector(
      selfIdentity: identity,
      discovery: discovery,
      server: server,
      retryInterval: scanInterval,
    )..start();

    final peer = CxpFakePeer._(
      identity: identity,
      server: server,
      writer: writer,
      discovery: discovery,
      connector: connector,
    );
    peer._sub = server.inbound.listen(peer.received.add);
    return peer;
  }

  /// Whether [server] currently sees [peerId] connected — either via an
  /// inbound handshake or an attached outbound link.
  bool isConnectedTo(String peerId) =>
      server.connectedPeers.any((p) => p.peerId == peerId);

  /// Tears down the connector, discovery watcher, manifest, and server,
  /// in the order that avoids a dangling retry/reconnect.
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    await connector.stop();
    await discovery.stop();
    await writer.remove();
    await server.stop();
  }
}
