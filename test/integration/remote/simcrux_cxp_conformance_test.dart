// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'dart:io';

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/inspector/services/editor_launcher.dart';
import 'package:simcrux/features/inspector/services/editor_launcher_provider.dart';
import 'package:simcrux/features/remote/providers/inbound_request_handler.dart';
import 'package:simcrux/features/remote/providers/notify_selection_emitter.dart';
import 'package:simcrux/features/remote/services/cross_probe_selection.dart';
import 'package:simcrux/features/workspace/providers/recent_lists.dart';
import 'package:simcrux/services/remote/cxp/simcrux_cxp_identity.dart';

import '../../support/cxp_runtime_harness.dart';
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

/// A peer product's handler: records every highlight and honours it.
class _PeerHandler extends CruxCxpRequestHandler {
  final List<ElementId> highlighted = <ElementId>[];

  @override
  Future<CruxCxpHandlerResult> highlight(
    RequestHighlight request,
    PeerIdentity from,
  ) async {
    highlighted.add(request.element);
    return CruxCxpHandlerResult.ok;
  }
}

void main() {
  late Directory manifests;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    manifests = cxpTestManifestDirectory();
  });

  group('SimCrux on the shared CXP runtime: two products', () {
    /// A second product on the same machine: its own root container, its own
    /// binding, the shared lifecycle. What WaveCrux, NetCrux and LintCrux
    /// each run.
    ProviderContainer peerProduct(String name, _PeerHandler handler) {
      final container = ProviderContainer(
        overrides: <Override>[
          cruxCxpProductBindingProvider.overrideWithValue(
            CruxCxpProductBinding(
              productName: name,
              defaultPort: 54329,
              prefsPrefix: '$name.',
              acceptedKinds: const <ElementKind>[
                ElementKind.signal,
                ElementKind.source,
                ElementKind.scope,
              ],
            ),
          ),
          cruxCxpManifestDirectoryProvider.overrideWith(
            (_) async => manifests.path,
          ),
          cruxCxpTransportAvailableProvider.overrideWithValue(true),
          cruxCxpLaunchSettingsProvider.overrideWithValue(
            const CruxCxpSettings(enabled: true, port: 0),
          ),
          cruxCxpRequestHandlerProvider.overrideWithValue(handler),
        ],
      )..listen(cruxCxpPeersProvider, (_, _) {});
      addTearDown(container.dispose);
      return container;
    }

    test('a test row cross-probed to WaveCrux arrives as its waveform, and to '
        'NetCrux as a scope', () async {
      final sim = simcruxCxpRuntimeContainer(manifestDirectory: manifests);
      final simRuntime = await runningCxpRuntime(sim);

      final wave = _PeerHandler();
      final net = _PeerHandler();
      final waveContainer = peerProduct('wavecrux', wave);
      final netContainer = peerProduct('netcrux', net);
      await waveContainer.read(cruxCxpRuntimeProvider.future);
      await netContainer.read(cruxCxpRuntimeProvider.future);

      final connected = await pollUntil(
        () =>
            simRuntime.peers.any((p) => p.productName == 'wavecrux') &&
            simRuntime.peers.any((p) => p.productName == 'netcrux'),
      );
      expect(connected, isTrue, reason: 'expected both peers to connect');

      final waveform = p.join(manifests.path, 'dump.vcd');
      final row = DashboardRow(
        result: TestResult(
          testId: 'cpu_unit/test_alu',
          runId: 'run-1',
          status: TestStatus.pass,
          startedAt: DateTime.utc(2026, 10, 20),
          finishedAt: DateTime.utc(2026, 10, 20),
          waveformPath: waveform,
        ),
        suiteName: 'cpu_unit',
        simulatorId: 'icarus',
        testName: 'test_alu',
      );
      final selection = crossProbeSelectionForRow(row);
      final dispatcher = sim.read(crossProbeDispatcherProvider);

      for (final peer in simRuntime.peers) {
        final outcome = await dispatcher.send(peer, selection);
        expect(outcome.kind, CrossProbeOutcomeKind.sent, reason: '$peer');
      }

      expect(wave.highlighted.single.kind, ElementKind.source);
      expect(wave.highlighted.single.path, waveform);
      expect(net.highlighted.single.kind, ElementKind.scope);
      expect(net.highlighted.single.path, 'cpu_unit/test_alu');
    });

    test(
      'SimCrux announces what it can show, so a peer sends it only that',
      () async {
        final sim = simcruxCxpRuntimeContainer(manifestDirectory: manifests);
        final runtime = await runningCxpRuntime(sim);

        final capabilities = runtime.selfIdentity.capabilities;
        expect(capabilities, containsAll(kSimcruxCxpCapabilities));
        for (final kind in <String>[
          'test',
          'source',
          'signal',
          'net',
          'port',
          'instance',
          'scope',
        ]) {
          expect(capabilities, contains('cxp.accepts:$kind'));
        }
        expect(capabilities, isNot(contains('cxp.accepts:marker')));
        expect(runtime.selfIdentity.productName, simcruxCxpProductName);
      },
    );
  });

  group('SimCrux CXP server: end-to-end conformance', () {
    /// Peer id of the conformance client. Shared so the identity the
    /// client announces and the subscription-registration poll that gates
    /// every broadcast case cannot drift apart.
    const peerId = 'cxp-conformance-peer';

    late ProviderContainer container;
    late CruxCxpRuntime runtime;
    late LocalCxpClient peer;
    late _RecordingLauncher launcher;

    Future<void> bootPair() async {
      launcher = _RecordingLauncher();
      final captured = CapturedCxpServer();
      // The production binding on an OS-picked port: it carries the
      // production wire screen, CXP §11's floor, into `LocalCxpServer`. The
      // rooted rule is applied by the request handler, on the path it is
      // about to hand an editor (`kCxpOpenArtifactContainment` says why the
      // wire is not rooted).
      container = simcruxCxpRuntimeContainer(
        manifestDirectory: manifests,
        capture: captured,
        extra: <Override>[
          cruxCxpRequestHandlerProvider.overrideWith(
            SimcruxCxpRequestHandler.new,
          ),
          editorLauncherProvider.overrideWithValue(launcher),
        ],
      );
      // The user has opened a config under `/abs`, which makes `/abs` one of
      // the containment roots (through the recent-projects list).
      final recents = container.read(recentProjects.provider.notifier);
      await recents.restored;
      recents.markOpened(_abs('/abs/simcrux.yaml'));
      runtime = await runningCxpRuntime(container);
      // Anchor the emitter and the project opener.
      container
        ..read(notifySelectionEmitterProvider)
        ..read(cxpProjectOpenerPublisherProvider);

      peer = LocalCxpClient(
        selfIdentity: const PeerIdentity(
          peerId: peerId,
          productName: 'test-peer',
          productVersion: '0.0.0',
        ),
      );
      await peer.connect(
        host: '127.0.0.1',
        port: runtime.boundPort!,
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
        () => captured.server!.debugSubscriptionsOf(peerId).isNotEmpty,
      );
      expect(
        subscribed,
        isTrue,
        reason: 'the subscription must register before any broadcast',
      );
    }

    Future<void> teardownPair() => peer.dispose();

    test('handshake + Subscribe completes successfully', () async {
      await bootPair();
      addTearDown(teardownPair);

      expect(peer.isConnected, isTrue);
      expect(peer.remotePeer?.productName, simcruxCxpProductName);
      expect(runtime.peers, hasLength(1));
      expect(runtime.peers.single.peerId, peerId);
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
      expect(container.read(selectedTestIdProvider), 'suiteA/testB');
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
        stranger.connect(host: '127.0.0.1', port: runtime.boundPort!),
        throwsA(
          isA<CxpHandshakeException>().having(
            (e) => e.code,
            'code',
            CxpErrorCode.unauthorized,
          ),
        ),
      );
      expect(
        runtime.peers.map((p) => p.peerId),
        isNot(contains('cxp-conformance-stranger')),
      );
    });

    test('the cross-probe event log records both directions', () async {
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
          .where((e) => e.direction == CrossProbeEventDirection.outbound)
          .toList();
      List<CrossProbeEvent> inboundOf(List<CrossProbeEvent> all) => all
          .where((e) => e.direction == CrossProbeEventDirection.inbound)
          .where((e) => e.kind == CrossProbeEventKind.highlightReceived)
          .toList();
      final landed = await pollUntil(() {
        final all = container.read(cruxCxpEventLogProvider);
        return outboundOf(all).isNotEmpty && inboundOf(all).isNotEmpty;
      });
      expect(landed, isTrue, reason: 'expected both directions to land');

      final events = container.read(cruxCxpEventLogProvider);
      final inbound = inboundOf(events);
      // SimCrux's notify_selection emitter is symmetric: an inbound
      // RequestHighlight that triggers a local selection change also
      // re-broadcasts a NotifySelection, so there are outbound events too.
      expect(
        outboundOf(events).any(
          (e) => e.messageKind == CxpMessageKind.notifySelection,
        ),
        isTrue,
      );
      expect(inbound, hasLength(1));
      expect(inbound.single.messageKind, CxpMessageKind.requestHighlight);
    });

    test('Goodbye disconnects the peer cleanly', () async {
      await bootPair();
      addTearDown(teardownPair);

      // Disconnect the client; the disconnect handler should clean up
      // the runtime's peers snapshot.
      await peer.disconnect();
      // Wait for the disconnect to propagate.
      final disconnected = await pollUntil(
        () => runtime.peers.isEmpty,
        timeout: const Duration(seconds: 2),
        interval: const Duration(milliseconds: 100),
      );
      expect(disconnected, isTrue, reason: 'expected the peer to disconnect');
      expect(runtime.peers, isEmpty);
    });
  });
}

/// [posix] as an absolute path on this platform: unchanged on macOS and
/// Linux, and on the working drive on Windows. There a drive-less `/abs` is
/// rooted but not absolute, and the CXP floor refuses it before the handler
/// sees it.
String _abs(String posix) => p.normalize(p.absolute(posix));
