// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_cxp/crux_cxp.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/remote/providers/cxp_server_provider.dart';
import 'package:simcrux/services/remote/cxp/simcrux_cxp_discovery.dart';
import 'package:simcrux/services/remote/cxp/simcrux_cxp_server.dart';

/// Factory the lifecycle controller uses to construct the
/// [SimCruxCxpDiscoveryService]. Tests override with a service rooted
/// at a temp directory; the production default resolves the suite-shared
/// manifest directory (`sharedCxpManifestDirectory()` from `crux_cxp`).
typedef SimCruxCxpDiscoveryFactory =
    Future<SimCruxCxpDiscoveryService> Function();

Future<SimCruxCxpDiscoveryService> _defaultDiscoveryFactory() =>
    SimCruxCxpDiscoveryService.create();

/// Override-point for tests. Replace with a factory that returns a
/// service rooted at a temp directory so the test suite never touches
/// the user's real app support directory.
final Provider<SimCruxCxpDiscoveryFactory> cxpDiscoveryFactoryProvider =
    Provider<SimCruxCxpDiscoveryFactory>((ref) => _defaultDiscoveryFactory);

/// Whether this platform can publish and scan CXP manifests.
///
/// False on web: discovery resolves a directory from the process environment
/// (`sharedCxpManifestDirectory`) and watches it on disk, none of which exists
/// in a browser, and the resolver throws there. The web dashboard viewer
/// (`lib/main_web.dart`) never builds this provider; the guard keeps the
/// desktop entrypoint safe if it is run in a browser. Overridden in tests.
final Provider<bool> cxpDiscoverySupportedProvider = Provider<bool>(
  (_) => !kIsWeb,
);

/// The running discovery service, or `null` when CXP is disabled or
/// the underlying server has not yet bound a port.
///
/// Watches [cxpServerProvider] — when the server starts, the manifest
/// is written and the watcher starts; when the server stops, the
/// manifest is removed and the watcher is torn down. Each restart
/// produces a fresh manifest with a fresh `started_at` timestamp.
final AsyncNotifierProvider<CxpDiscoveryNotifier, SimCruxCxpDiscoveryService?>
cxpDiscoveryProvider =
    AsyncNotifierProvider<CxpDiscoveryNotifier, SimCruxCxpDiscoveryService?>(
      CxpDiscoveryNotifier.new,
    );

/// Lifecycle controller for the discovery service.
class CxpDiscoveryNotifier extends AsyncNotifier<SimCruxCxpDiscoveryService?> {
  @override
  Future<SimCruxCxpDiscoveryService?> build() async {
    if (!ref.watch(cxpDiscoverySupportedProvider)) return null;
    final serverAsync = ref.watch(cxpServerProvider);
    final server = serverAsync.value;
    if (server == null) return null;

    final factory = ref.read(cxpDiscoveryFactoryProvider);
    final service = await factory();
    // `server.server` (the underlying CxpServer) is guaranteed non-null
    // here: cxpServerProvider only resolves to a non-null SimCruxCxpServer
    // after its build() has awaited server.start() to completion, and
    // this provider watches cxpServerProvider — so by the time this line
    // runs, start() has already set the field. Required so the peer
    // connector routes connector-linked traffic into this process's
    // dispatch stream; see SimCruxCxpDiscoveryService.start's doc.
    await service.start(
      identity: server.selfIdentity,
      host: '127.0.0.1',
      port: server.boundPort ?? defaultSimcruxCxpPort,
      server: server.server!,
    );

    ref.onDispose(() {
      unawaited(service.stop());
    });

    return service;
  }
}

/// Snapshot of currently-known peer manifests.
///
/// Backed by an in-memory list the [CxpPeersNotifier] maintains from the
/// running discovery service's event stream. Returns an empty list when
/// discovery is not running.
final NotifierProvider<CxpPeersNotifier, List<CxpPeerManifest>>
cxpPeersProvider = NotifierProvider<CxpPeersNotifier, List<CxpPeerManifest>>(
  CxpPeersNotifier.new,
);

/// Current set of discovered peers the connector cannot open a socket to.
///
/// One entry per peer whose manifest exists (so discovery surfaced it)
/// but whose outbound dial keeps failing. Backed by [CxpDialFailuresNotifier],
/// which mirrors the connector's authoritative `lastDialFailures` map.
/// Empty list when discovery is not running or every peer is reachable —
/// so a consumer can render nothing when there is nothing wrong.
final NotifierProvider<CxpDialFailuresNotifier, List<CxpDialFailure>>
cxpDialFailuresProvider =
    NotifierProvider<CxpDialFailuresNotifier, List<CxpDialFailure>>(
      CxpDialFailuresNotifier.new,
    );

/// Notifier backing [cxpDialFailuresProvider].
///
/// The connector's `lastDialFailures` map is the source of truth: it adds
/// an entry on each failed dial and removes it on a successful handshake
/// or a manifest removal. This notifier re-reads that map whenever a dial
/// attempt fails or the discovered-peer set changes, so both new failures
/// and recoveries/removals surface. A peer that recovers with no other CXP
/// activity clears on the next retry tick or discovery change (the
/// connector re-dials still-down peers every retry interval, so down peers
/// stay fresh); this deliberately avoids editing the shared connector to
/// emit a dedicated "recovered" event.
class CxpDialFailuresNotifier extends Notifier<List<CxpDialFailure>> {
  @override
  List<CxpDialFailure> build() {
    final serviceAsync = ref.watch(cxpDiscoveryProvider);
    final service = serviceAsync.value;
    if (service == null) return const <CxpDialFailure>[];

    List<CxpDialFailure> snapshot() =>
        List<CxpDialFailure>.unmodifiable(service.lastDialFailures.values);

    final failSub = service.dialFailures.listen((_) => state = snapshot());
    ref.onDispose(failSub.cancel);
    // Manifest add/remove events clear entries for peers that vanished and
    // give a prompt refresh point for recoveries.
    final discSub = service.discovery.events.listen((_) => state = snapshot());
    ref.onDispose(discSub.cancel);

    return snapshot();
  }
}

/// Notifier backing [cxpPeersProvider].
///
/// Seeds itself from the running discovery service's pre-existing
/// `peers` snapshot (so a late subscriber sees peers that already
/// appeared) and then mutates the list per inbound event.
class CxpPeersNotifier extends Notifier<List<CxpPeerManifest>> {
  @override
  List<CxpPeerManifest> build() {
    final serviceAsync = ref.watch(cxpDiscoveryProvider);
    final service = serviceAsync.value;
    if (service == null) return const <CxpPeerManifest>[];

    // The manifest directory is suite-shared, so the raw scan always
    // contains SimCrux's OWN manifest — filter it from both the seed
    // snapshot and the event stream, or the cross-probe panel lists
    // this very process as a peer.
    final selfPeerId = ref.read(cxpServerProvider).value?.selfIdentity.peerId;

    final initial = List<CxpPeerManifest>.from(
      service.discovery.peers.where(
        (m) => m.identity.peerId != selfPeerId,
      ),
    );

    final sub = service.discovery.events.listen((event) {
      if (event.manifest.identity.peerId == selfPeerId) return;
      final current = List<CxpPeerManifest>.from(state)
        ..removeWhere(
          (m) => m.identity.peerId == event.manifest.identity.peerId,
        );
      if (event.added) {
        current.add(event.manifest);
      }
      state = List<CxpPeerManifest>.unmodifiable(current);
    });
    ref.onDispose(sub.cancel);

    return List<CxpPeerManifest>.unmodifiable(initial);
  }
}
