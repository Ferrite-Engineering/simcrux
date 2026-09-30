// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_window_chrome/crux_window_chrome.dart';
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
import 'package:simcrux/features/remote/providers/cross_probe_events_provider.dart';
import 'package:simcrux/features/remote/providers/cxp_server_provider.dart';
import 'package:simcrux/features/remote/providers/inbound_request_handler.dart';
import 'package:simcrux/features/remote/providers/notify_selection_emitter.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/services/remote/cxp/simcrux_cxp_server.dart';

import '../../support/answered_telemetry.dart';
import '../../support/poll_until.dart';

/// Stub editor launcher that records every invocation without
/// shelling out to a real editor process.
class _RecordingLauncher implements EditorLauncher {
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
    return true;
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // Honored inbound messages fire `requestUserAttention()`. This is a
    // binding-less `dart:test` suite, so gate the requester to the no-op
    // backend (as the settings bridge does when the preference is off) rather
    // than let the default method-channel backend throw on the missing binding.
    windowAttentionRequester = const NoopWindowAttentionRequester();
  });

  tearDown(() {
    windowAttentionRequester = const MethodChannelWindowAttentionRequester();
  });

  group('SimCruxCxpServer — end-to-end conformance', () {
    /// Peer id of the conformance client. Shared so the identity the
    /// client announces and the subscription-registration poll that gates
    /// every broadcast case cannot drift apart.
    const peerId = 'cxp-conformance-peer';

    late ProviderContainer container;
    late SimCruxCxpServer server;
    late LocalCxpClient peer;
    late _RecordingLauncher launcher;

    Future<void> bootPair() async {
      launcher = _RecordingLauncher();
      container = ProviderContainer(
        overrides: <Override>[
          ...answeredTelemetryOverrides(),
          // The production factory on an OS-picked port: it carries the
          // production wire screen, CXP §11's floor, into `LocalCxpServer`.
          // The rooted rule is applied by the inbound handler, on the path
          // it is about to hand an editor (`kCxpOpenArtifactContainment`
          // says why the wire is not rooted).
          cxpServerFactoryProvider.overrideWith(
            (ref) =>
                ({required selfIdentity, required port}) => SimCruxCxpServer(
                  selfIdentity: selfIdentity,
                  port: 0,
                ),
          ),
          editorLauncherProvider.overrideWithValue(launcher),
        ],
      );
      await container.read(appSettingsProvider.future);
      // The user has opened a config under `/abs`, which makes `/abs` one of
      // the containment roots (through the recent-projects list).
      await container
          .read(appSettingsProvider.notifier)
          .addRecentProject(_abs('/abs/simcrux.yaml'));
      final s = await container.read(cxpServerProvider.future);
      expect(s, isNotNull);
      server = s!;
      // Anchor the emitter + handler.
      container
        ..read(notifySelectionEmitterProvider)
        ..read(inboundRequestHandlerProvider);

      peer = LocalCxpClient(
        selfIdentity: const PeerIdentity(
          peerId: peerId,
          productName: 'test-peer',
          productVersion: '0.0.0',
        ),
      );
      await peer.connect(
        host: '127.0.0.1',
        port: server.boundPort!,
        token: cxpProcessAuthToken,
      );
      // Subscribe broadly so the peer receives everything SimCrux
      // might broadcast.
      peer.send(
        const Subscribe(
          subscriptions: <CxpSubscription>[
            CxpSubscription(messageKind: CxpMessageKind.notifySelection),
            CxpSubscription(messageKind: CxpMessageKind.requestHighlight),
            CxpSubscription(messageKind: CxpMessageKind.requestHighlightAck),
            CxpSubscription(messageKind: CxpMessageKind.requestOpenSource),
            CxpSubscription(messageKind: CxpMessageKind.requestOpenSourceAck),
          ],
        ),
      );
      // The Subscribe crosses a real socket and registers asynchronously.
      // `broadcast` consults the recorded subscription set and silently
      // drops the frame for a peer that has none yet — and every message
      // here is fire-and-forget, so a frame dropped in that window is
      // never retried. A fixed grace period only decides whether the
      // window is usually wide enough on an idle machine; wait on the
      // registration itself instead.
      final subscribed = await pollUntil(
        () => server.server!.debugSubscriptionsOf(peerId).isNotEmpty,
      );
      expect(
        subscribed,
        isTrue,
        reason: 'the subscription must register before any broadcast',
      );
    }

    Future<void> teardownPair() async {
      await peer.dispose();
      container.dispose();
    }

    test('handshake + Subscribe completes successfully', () async {
      await bootPair();
      addTearDown(teardownPair);

      expect(peer.isConnected, isTrue);
      expect(peer.remotePeer?.productName, simcruxCxpProductName);
      expect(server.connectedPeers, hasLength(1));
      expect(server.connectedPeers.single.peerId, peerId);
    });

    test('selecting a test broadcasts NotifySelection', () async {
      await bootPair();
      addTearDown(teardownPair);

      final received = peer.inbound.firstWhere(
        (m) => m.message is NotifySelection,
      );
      container
          .read(selectedTestIdProvider.notifier)
          .select('cpu_unit/test_alu_basic');
      final msg =
          (await received.timeout(const Duration(seconds: 2))).message
              as NotifySelection;
      expect(msg.elements.single.kind, ElementKind.test);
      expect(msg.elements.single.path, 'cpu_unit/test_alu_basic');
    });

    test(
      'source navigation broadcasts NotifySelection (ElementKind.source)',
      () async {
        await bootPair();
        addTearDown(teardownPair);

        final received = peer.inbound.firstWhere(
          (m) => m.message is NotifySelection,
        );
        container
            .read(explicitSourceSelectionProvider.notifier)
            .select('/abs/rtl/alu.sv');
        final msg =
            (await received.timeout(const Duration(seconds: 2))).message
                as NotifySelection;
        expect(msg.elements.single.kind, ElementKind.source);
        expect(msg.elements.single.path, '/abs/rtl/alu.sv');
      },
    );

    test('RequestHighlight (test) → selects the test + acks honored', () async {
      await bootPair();
      addTearDown(teardownPair);

      // Load a config carrying the requested test so the handler's
      // honest-ack existence check passes (an unknown test id acks
      // honored:false without selecting).
      container
          .read(activeConfigProvider.notifier)
          .replace(
            RegressionConfig(
              projectFilePath: '/p/a.yaml',
              schemaVersion: '1',
              suites: [
                Suite(
                  name: 'suiteA',
                  tests: [
                    TestSpec(
                      id: 'suiteA/testB',
                      name: 'testB',
                      suiteName: 'suiteA',
                      simulatorId: 'icarus',
                      top: 'tb',
                    ),
                  ],
                ),
              ],
              simulatorBinaries: const {},
            ),
          );

      final ackFuture = peer.inbound.firstWhere(
        (m) => m.message is RequestHighlightAck,
      );
      peer.send(
        const RequestHighlight(
          element: ElementId(kind: ElementKind.test, path: 'suiteA/testB'),
        ),
      );
      final ack =
          (await ackFuture.timeout(const Duration(seconds: 2))).message
              as RequestHighlightAck;
      expect(ack.honored, isTrue);
      expect(
        container.read(selectedTestIdProvider),
        'suiteA/testB',
      );
    });

    test(
      'RequestHighlight (signal) → filters dashboard + acks honored',
      () async {
        await bootPair();
        addTearDown(teardownPair);

        final ackFuture = peer.inbound.firstWhere(
          (m) => m.message is RequestHighlightAck,
        );
        peer.send(
          const RequestHighlight(
            element: ElementId(
              kind: ElementKind.signal,
              path: 'top.cpu.alu.sum[31:0]',
            ),
          ),
        );
        final ack =
            (await ackFuture.timeout(const Duration(seconds: 2))).message
                as RequestHighlightAck;
        expect(ack.honored, isTrue);
        expect(
          container.read(dashboardFilterProvider).testNameSubstring,
          'sum',
        );
      },
    );

    test('RequestHighlight (breakpoint) → acks honored:false with a clear '
        'reason (editor not implemented)', () async {
      await bootPair();
      addTearDown(teardownPair);

      final ackFuture = peer.inbound.firstWhere(
        (m) => m.message is RequestHighlightAck,
      );
      peer.send(
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

    test('RequestOpenSource → invokes the configured editor', () async {
      await bootPair();
      addTearDown(teardownPair);

      final ackFuture = peer.inbound.firstWhere(
        (m) => m.message is RequestOpenSourceAck,
      );
      final alu = _abs('/abs/rtl/alu.sv');
      peer.send(RequestOpenSource(filePath: alu, line: 42, column: 8));
      final ack =
          (await ackFuture.timeout(const Duration(seconds: 2))).message
              as RequestOpenSourceAck;
      expect(ack.honored, isTrue);
      expect(launcher.calls.single.filePath, alu);
      expect(launcher.calls.single.line, 42);
      expect(launcher.calls.single.column, 8);
    });

    test('RequestOpenSource outside the opened directories → refused, and no '
        'editor runs', () async {
      await bootPair();
      addTearDown(teardownPair);

      final ackFuture = peer.inbound.firstWhere(
        (m) => m.message is RequestOpenSourceAck,
      );
      final passwd = _abs('/etc/passwd');
      peer.send(RequestOpenSource(filePath: passwd, line: 1));
      final ack =
          (await ackFuture.timeout(const Duration(seconds: 2))).message
              as RequestOpenSourceAck;
      expect(ack.honored, isFalse);
      expect(ack.reason, contains('outside the directories'));
      // CXP §9.11: the reason never echoes the sender's path back.
      expect(ack.reason, isNot(contains(passwd)));
      expect(launcher.calls, isEmpty);
    });

    test('a peer that does not present the token is refused', () async {
      await bootPair();
      addTearDown(teardownPair);

      final stranger = LocalCxpClient(
        selfIdentity: const PeerIdentity(
          peerId: 'cxp-conformance-stranger',
          productName: 'test-peer',
          productVersion: '0.0.0',
        ),
      );
      addTearDown(stranger.dispose);
      await expectLater(
        stranger.connect(host: '127.0.0.1', port: server.boundPort!),
        throwsA(
          isA<CxpHandshakeException>().having(
            (e) => e.code,
            'code',
            CxpErrorCode.unauthorized,
          ),
        ),
      );
      expect(
        server.connectedPeers.map((p) => p.peerId),
        isNot(contains('cxp-conformance-stranger')),
      );
    });

    test('cross-probe events buffer records both directions', () async {
      await bootPair();
      addTearDown(teardownPair);

      // Outbound: test selection broadcast.
      container.read(selectedTestIdProvider.notifier).select('suiteA/testB');
      // Inbound: peer sends a RequestHighlight.
      peer.send(
        const RequestHighlight(
          element: ElementId(kind: ElementKind.test, path: 'suiteX/testY'),
        ),
      );
      // Wait for both directions to land.
      List<CrossProbeEvent> outboundOf(List<CrossProbeEvent> all) => all
          .where((e) => e.direction == CrossProbeDirection.outbound)
          .toList();
      List<CrossProbeEvent> inboundOf(List<CrossProbeEvent> all) =>
          all.where((e) => e.direction == CrossProbeDirection.inbound).toList();
      final landed = await pollUntil(() {
        final all = container.read(crossProbeEventsProvider);
        return outboundOf(all).isNotEmpty && inboundOf(all).isNotEmpty;
      });
      expect(landed, isTrue, reason: 'expected both directions to land');

      final events = container.read(crossProbeEventsProvider);
      final outbound = outboundOf(events);
      final inbound = inboundOf(events);
      // SimCrux's notify_selection emitter is symmetric: an inbound
      // RequestHighlight that triggers a local selection change also
      // re-broadcasts a NotifySelection. So we see 2+ outbound events
      // here (our initial select + the rebroadcast after the inbound
      // request).
      expect(outbound.length, greaterThanOrEqualTo(1));
      expect(
        outbound.every((e) => e.kind == CxpMessageKind.notifySelection),
        isTrue,
      );
      expect(inbound, hasLength(1));
      expect(inbound.single.kind, CxpMessageKind.requestHighlight);
    });

    test('Goodbye disconnects the peer cleanly', () async {
      await bootPair();
      addTearDown(teardownPair);

      // Disconnect the client; the disconnect handler should clean up
      // the server's connectedPeers snapshot.
      await peer.disconnect();
      // Wait for the disconnect to propagate.
      final disconnected = await pollUntil(
        () => server.connectedPeers.isEmpty,
        timeout: const Duration(seconds: 2),
        interval: const Duration(milliseconds: 100),
      );
      expect(disconnected, isTrue, reason: 'expected the peer to disconnect');
      expect(server.connectedPeers, isEmpty);
    });
  });
}

/// [posix] as an absolute path on this platform: unchanged on macOS and
/// Linux, and on the working drive on Windows. There a drive-less `/abs` is
/// rooted but not absolute, and the CXP floor refuses it before the handler
/// sees it.
String _abs(String posix) => p.normalize(p.absolute(posix));
