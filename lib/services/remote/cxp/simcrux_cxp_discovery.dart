// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_cxp/crux_cxp.dart';

/// Resolves the suite-shared CXP manifest directory for the running
/// platform via `sharedCxpManifestDirectory()` (crux_cxp) and creates
/// it if it does not exist.
///
/// Every Crux product writes into (and scans) the SAME folder so peers
/// can discover each other without any cross-product knowledge — the
/// manifest contents identify the product and version.
///
/// > **Why not `getApplicationSupportDirectory()`.** That path is
/// > bundle-id-scoped per app on every desktop platform, so each product
/// > would publish into its own private container that no peer ever
/// > scans — CXP discovery depends on every product writing into (and
/// > reading from) the identical shared location. The shared resolver
/// > derives a bundle-independent, per-user location from the
/// > environment alone.
///
/// Override in tests by injecting a different
/// [resolveManifestDirectory] function.
Future<String> defaultResolveManifestDirectory() async {
  final dir = Directory(sharedCxpManifestDirectory());
  if (!dir.existsSync()) {
    await dir.create(recursive: true);
  }
  return dir.path;
}

/// Owns the discovery surface for SimCrux:
///   - Resolves the suite-shared manifest directory
///     ([defaultResolveManifestDirectory])
///   - Publishes SimCrux's manifest on start, removes it on stop
///   - Wraps a [CxpDiscovery] watcher consumers can subscribe to
///
/// One instance per running SimCrux process. Created by the lifecycle
/// provider in `cxp_discovery_provider.dart` once the CXP server has bound
/// to a port and produced a [PeerIdentity].
class SimCruxCxpDiscoveryService {
  /// Creates a discovery service rooted at [manifestDirectory].
  ///
  /// Tests pass an explicit directory and skip the shared-directory
  /// lookup. The production path is to call [SimCruxCxpDiscoveryService.create].
  SimCruxCxpDiscoveryService({
    required this.manifestDirectory,
    CxpDiscovery? discovery,
    CxpManifestWriter? writer,
    Duration scanInterval = const Duration(seconds: 2),
    Duration staleThreshold = const Duration(minutes: 5),
  }) : _discovery =
           discovery ??
           CxpDiscovery(
             manifestDirectory: manifestDirectory,
             scanInterval: scanInterval,
             staleThreshold: staleThreshold,
           ),
       _writer =
           writer ?? CxpManifestWriter(manifestDirectory: manifestDirectory);

  /// Production constructor — resolves the suite-shared manifest
  /// directory via [resolveManifestDirectory]. Tests should use the default
  /// constructor with an explicit directory.
  static Future<SimCruxCxpDiscoveryService> create({
    Future<String> Function() resolveManifestDirectory =
        defaultResolveManifestDirectory,
  }) async {
    final dir = await resolveManifestDirectory();
    return SimCruxCxpDiscoveryService(manifestDirectory: dir);
  }

  /// Filesystem path of the shared discovery directory.
  final String manifestDirectory;

  final CxpDiscovery _discovery;
  final CxpManifestWriter _writer;
  CxpPeerConnector? _connector;

  bool _started = false;

  /// Underlying watcher consumers subscribe to.
  CxpDiscovery get discovery => _discovery;

  /// The peer connector dialing every discovered non-self manifest, or
  /// null while stopped. Exposed for tests.
  CxpPeerConnector? get connector => _connector;

  /// Stream of outbound dial failures from the running connector — one
  /// event per failed attempt to open a socket to a discovered peer.
  ///
  /// A discovered manifest only proves a peer's file exists; the dial can
  /// still fail (peer not yet listening, crashed without removing its
  /// manifest, wrong port). This surfaces those so an unreachable peer is
  /// distinguishable from an absent one. Empty stream while stopped.
  Stream<CxpDialFailure> get dialFailures =>
      _connector?.dialFailures ?? const Stream<CxpDialFailure>.empty();

  /// The most recent dial failure per currently-unreachable peer.
  ///
  /// The connector maintains this authoritatively: an entry appears when a
  /// dial fails and is removed when the peer's handshake later succeeds or
  /// its manifest is removed. Empty while stopped.
  Map<String, CxpDialFailure> get lastDialFailures =>
      _connector?.lastDialFailures ?? const <String, CxpDialFailure>{};

  /// Whether [start] has been called and [stop] has not yet been.
  bool get isRunning => _started;

  /// Publish SimCrux's manifest, start the watcher, and dial peers.
  ///
  /// [server] is SimCrux's own running [CxpServer] — required, not
  /// optional. With two symmetric dialers (every Crux product runs a
  /// connector alongside its server), a message this process sends via
  /// `server.sendTo`/`broadcast` can land on the socket the OTHER
  /// side's connector dialed, so the reply (or any directed message
  /// the peer originates) arrives back on OUR OWN connector's outbound
  /// client link — never on our server's accept loop. Passing [server]
  /// wires that link into [CxpServer.injectInbound] /
  /// [CxpServer.attachLinkedPeer] so it is merged into the one
  /// `server.inbound` stream every SimCrux request handler subscribes
  /// to. Without it, `CxpPeerConnector` degrades to presence-only
  /// dialing: `connectedPeers` looks correct but every inbound request,
  /// ack, and notify_selection gossip arriving over a connector-dialed
  /// link is silently dropped. See `CxpPeerConnector`'s class doc (the
  /// "connector<->server seam") and the crux_cxp e2e conformance suite
  /// this mirrors (`peer_connectivity_test.dart`'s "end-to-end product
  /// traffic" case).
  Future<void> start({
    required PeerIdentity identity,
    required String host,
    required int port,
    required CxpServer server,
  }) async {
    if (_started) return;
    _started = true;
    await _writer.write(identity: identity, host: host, port: port);
    await _discovery.start();
    // Dial every discovered non-self peer so its server sees an inbound
    // Hello (and its symmetric connector dials our server back, which is
    // what fills OUR connectedPeers — the list the cross-probe menu and
    // Debug-in-WaveCrux dispatcher gate on). Without this, discovery
    // surfaces manifests but no CXP socket is ever opened anywhere in
    // the suite.
    _connector = CxpPeerConnector(
      selfIdentity: identity,
      discovery: _discovery,
      server: server,
    )..start();
  }

  /// Stop the connector and watcher and remove SimCrux's manifest.
  /// Idempotent.
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    final connector = _connector;
    _connector = null;
    if (connector != null) {
      await connector.stop();
    }
    await _writer.remove();
    await _discovery.stop();
  }
}
