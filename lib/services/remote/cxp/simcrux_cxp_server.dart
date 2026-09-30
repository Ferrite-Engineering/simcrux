// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:crux_cxp/crux_cxp.dart';
import 'package:meta/meta.dart';
import 'package:simcrux/core/app_info/build_info.dart';
import 'package:simcrux/services/remote/cxp/simcrux_name_resolver.dart';

/// Short product name announced in the CXP greeting. The four products
/// of the suite each use their lowercased product short-name; SimCrux's
/// is `simcrux`.
const String simcruxCxpProductName = SimCruxBuildInfo.productName;

/// Default CXP port for SimCrux's server.
///
/// Each Crux product uses a distinct port so all four can run side by
/// side on the same workstation without colliding (per
/// `crux-shared/packages/crux_cxp/README.md`): WaveCrux 54322,
/// NetCrux 54323, LintCrux 54324, SimCrux 54325. Override via the
/// `cxp.port` setting.
const int defaultSimcruxCxpPort = 54325;

/// Product version SimCrux announces in the CXP handshake.
///
/// Aliased to [SimCruxBuildInfo.productVersion] rather than held separately.
/// It used to be its own literal "kept in sync with `pubspec.yaml` by
/// convention", and the convention did not hold: it advertised `0.1.0` to
/// every peer of every 0.8.0 build. One constant, one guard test, no
/// convention to remember.
const String kSimcruxCxpAdvertisedVersion = SimCruxBuildInfo.productVersion;

/// Capabilities the SimCrux peer announces in [Hello].
///
/// v1 CXP does not yet define a `request_open_waveform` message kind;
/// SimCrux models the waveform-open semantics through
/// [ElementKind.source] with a waveform file extension (see
/// [SimCruxNameResolver]). Receivers that recognise the `simcrux.debug`
/// capability know that an [ElementKind.source] whose path looks like a
/// waveform should be opened in a viewer, not an editor.
const Set<String> kSimcruxCxpCapabilities = <String>{
  'simcrux.debug',
};

/// Compose the [PeerIdentity] this process announces over CXP.
///
/// The peer ID is conventionally `<product>-<pid>-<startedAtMillis>` so
/// the same machine running two SimCrux processes still gets distinct
/// peer IDs. Visible in the manifest filename and in the cross-probe
/// panel.
PeerIdentity buildSimcruxPeerIdentity({
  int? processId,
  DateTime? startedAt,
  String productVersion = kSimcruxCxpAdvertisedVersion,
}) {
  final actualPid = processId ?? pid;
  final stamp = (startedAt ?? DateTime.now().toUtc()).millisecondsSinceEpoch;
  return PeerIdentity(
    peerId: '$simcruxCxpProductName-$actualPid-$stamp',
    productName: simcruxCxpProductName,
    productVersion: productVersion,
    capabilities: kSimcruxCxpCapabilities,
  );
}

/// Thin wrapper around [LocalCxpServer] that knows about SimCrux's
/// resolver, port defaults, and self-identity.
///
/// Kept as a class (rather than a top-level factory) so consumers can
/// inject a fake / NoopCxpServer in tests via a `serverFactory`
/// indirection.
class SimCruxCxpServer {
  /// Creates a SimCrux-flavored CXP server.
  ///
  /// [port] = 0 lets the OS pick a free port — useful in tests. Wire
  /// the production default ([defaultSimcruxCxpPort]) at call sites.
  SimCruxCxpServer({
    PeerIdentity? selfIdentity,
    NameResolver? nameResolver,
    this.port = defaultSimcruxCxpPort,
    this.containment = const CxpPathContainment(),
    LocalCxpServer Function({
      required PeerIdentity selfIdentity,
      NameResolver? nameResolver,
      String host,
      int port,
      CxpPathContainment containment,
    })?
    serverFactory,
  }) : selfIdentity = selfIdentity ?? buildSimcruxPeerIdentity(),
       nameResolver = nameResolver ?? const SimCruxNameResolver(),
       _serverFactory = serverFactory ?? _defaultFactory;

  /// The identity SimCrux announces in CXP handshakes.
  final PeerIdentity selfIdentity;

  /// Resolver passed through to the underlying server.
  final NameResolver nameResolver;

  /// Requested bind port. `0` lets the OS pick a free port (tests).
  final int port;

  /// The receiver-side rule (CXP §11) every peer-supplied path is checked
  /// against, handed to [LocalCxpServer] so a `request_open_source`'s
  /// `file_path` or a `request_open_artifact`'s hint is screened before
  /// [inbound] ever carries it.
  ///
  /// The shared layer can only check the value that arrived on the wire; the
  /// value SimCrux is about to open, or hand to an editor argv, is checked by
  /// the inbound request handler under the rule that route keeps. The
  /// default is the floor (absolute, well-formed), and the provider layer
  /// supplies the floor too: one rule screens both requests here, and the
  /// artifact request's hint must not be rooted in the directories the user
  /// has opened (`kCxpOpenArtifactContainment`).
  final CxpPathContainment containment;

  final LocalCxpServer Function({
    required PeerIdentity selfIdentity,
    NameResolver? nameResolver,
    String host,
    int port,
    CxpPathContainment containment,
  })
  _serverFactory;

  LocalCxpServer? _server;

  /// The bound port after [start] resolves, or `null` before start.
  int? get boundPort => _server?.boundPort;

  /// Whether the server is currently running.
  bool get isRunning => _server != null;

  /// Underlying [LocalCxpServer] instance, after [start] has been
  /// awaited. Returns `null` when the server is stopped.
  ///
  /// Exposed so callers (notify_selection emitters, request handlers,
  /// cross-probe panel) can subscribe to `inbound` / `presence` and
  /// invoke `broadcast` / `sendTo` directly.
  LocalCxpServer? get server => _server;

  /// Start the underlying [LocalCxpServer]. Idempotent.
  Future<void> start() async {
    if (_server != null) return;
    final created = _serverFactory(
      selfIdentity: selfIdentity,
      nameResolver: nameResolver,
      port: port,
      host: '127.0.0.1',
      containment: containment,
    );
    await created.start();
    _server = created;
  }

  /// Stop the underlying server and release the bound port.
  Future<void> stop() async {
    final s = _server;
    if (s == null) return;
    _server = null;
    await s.stop();
  }

  /// Broadcast a message to every subscribed peer. No-op if stopped.
  void broadcast(CxpMessage message) {
    _server?.broadcast(message);
  }

  /// Targeted send to a specific peer. Returns `true` if delivered.
  /// Returns `false` if the server is stopped or the peer is unknown.
  bool sendTo(String peerId, CxpMessage message) {
    final s = _server;
    if (s == null) return false;
    return s.sendTo(peerId, message);
  }

  /// Sends [request] to [peerId] and waits for the peer's
  /// [RequestHighlightAck], so the cross-probe panel can surface a rejected
  /// send. Returns `(delivered: false, ack: null)` when stopped/unreachable, and
  /// `(delivered: true, ack: null)` when the send left but no ack arrived within
  /// [timeout]. Correlates by "the next RequestHighlightAck from [peerId]",
  /// unambiguous because such an ack only ever replies to a request_highlight
  /// and directed panel sends are the sole source of them.
  Future<({bool delivered, RequestHighlightAck? ack})> requestHighlight(
    String peerId,
    RequestHighlight request, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final s = _server;
    if (s == null) return (delivered: false, ack: null);
    final completer = Completer<RequestHighlightAck>();
    final sub = s.inbound.listen((inbound) {
      if (inbound.from.peerId == peerId &&
          inbound.message is RequestHighlightAck &&
          !completer.isCompleted) {
        completer.complete(inbound.message as RequestHighlightAck);
      }
    });
    final delivered = s.sendTo(peerId, request);
    if (!delivered) {
      await sub.cancel();
      return (delivered: false, ack: null);
    }
    RequestHighlightAck? ack;
    try {
      ack = await completer.future.timeout(timeout);
    } on TimeoutException {
      ack = null;
    } finally {
      await sub.cancel();
    }
    return (delivered: true, ack: ack);
  }

  /// Inbound message stream. Empty when stopped.
  Stream<InboundCxpMessage> get inbound =>
      _server?.inbound ?? const Stream<InboundCxpMessage>.empty();

  /// Presence event stream. Empty when stopped.
  Stream<PeerPresenceEvent> get presence =>
      _server?.presence ?? const Stream<PeerPresenceEvent>.empty();

  /// Snapshot of currently-connected peers. Empty when stopped.
  List<PeerIdentity> get connectedPeers =>
      _server?.connectedPeers ?? const <PeerIdentity>[];

  static LocalCxpServer _defaultFactory({
    required PeerIdentity selfIdentity,
    NameResolver? nameResolver,
    String host = '127.0.0.1',
    int port = 0,
    CxpPathContainment containment = const CxpPathContainment(),
  }) => LocalCxpServer(
    selfIdentity: selfIdentity,
    nameResolver: nameResolver,
    host: host,
    port: port,
    containment: containment,
  );
}

/// Test-only view-model: a single cross-probe event recorded by the
/// CXP panel's rolling buffer.
///
/// Lifted into the public surface so the panel widget and its tests
/// share a value object; not part of the wire format.
@immutable
class CrossProbeEvent {
  /// Creates an event record.
  const CrossProbeEvent({
    required this.timestamp,
    required this.direction,
    required this.kind,
    required this.peerId,
    this.summary,
  });

  /// When the event was recorded.
  final DateTime timestamp;

  /// `inbound` or `outbound` — which side initiated.
  final CrossProbeDirection direction;

  /// CXP message kind (one of [CxpMessageKind]).
  final String kind;

  /// Peer ID involved (sender for inbound, receiver for outbound).
  final String peerId;

  /// Optional one-line summary for display.
  final String? summary;
}

/// Direction discriminator for [CrossProbeEvent].
enum CrossProbeDirection {
  /// Message sent from this peer to another peer (broadcast or sendTo).
  outbound,

  /// Message received from another peer.
  inbound,
}
