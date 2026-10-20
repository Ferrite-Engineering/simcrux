// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'dart:io';

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/features/remote/services/debug_in_wavecrux_dispatcher.dart';
import 'package:simcrux/services/simulator/riscv_formal_driver.dart';

import '../../../support/answered_telemetry.dart';
import '../../../support/cxp_auto_ack.dart';
import '../../../support/cxp_fake_peer.dart';
import '../../../support/cxp_runtime_harness.dart';
import '../../../support/poll_until.dart';

void main() {
  // A real on-disk dump: the dispatcher guards against handing off a path
  // that no longer exists, so tests that expect to progress past that guard
  // must point at a file that actually exists.
  late File waveformFile;
  late Directory manifests;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    waveformFile = File(
      p.join(
        Directory.systemTemp.createTempSync('simcrux_wf_disp_').path,
        'dump.vcd',
      ),
    )..writeAsStringSync('VCD');
    manifests = cxpTestManifestDirectory();
  });

  tearDown(() {
    final dir = waveformFile.parent;
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('deriveSuggestedSignalsFromTopModule', () {
    test('returns <top>.* glob when top is provided', () {
      expect(
        deriveSuggestedSignalsFromTopModule('tb_alu'),
        <String>['tb_alu.*'],
      );
    });

    test('returns empty when top is null or empty', () {
      expect(deriveSuggestedSignalsFromTopModule(null), isEmpty);
      expect(deriveSuggestedSignalsFromTopModule(''), isEmpty);
    });
  });

  group('DebugInWaveCruxDispatcher — no waveform path', () {
    test('returns noWaveform when waveformPath is null', () async {
      final container = ProviderContainer(
        overrides: answeredTelemetryOverrides(),
      );
      addTearDown(container.dispose);

      final dispatcher = container.read(debugInWaveCruxDispatcherProvider);
      final result = await dispatcher.dispatch(waveformPath: null);
      expect(result.outcome, DebugInWaveCruxOutcome.noWaveform);
    });

    test('returns noWaveform when waveformPath is empty', () async {
      final container = ProviderContainer(
        overrides: answeredTelemetryOverrides(),
      );
      addTearDown(container.dispose);

      final dispatcher = container.read(debugInWaveCruxDispatcherProvider);
      final result = await dispatcher.dispatch(waveformPath: '');
      expect(result.outcome, DebugInWaveCruxOutcome.noWaveform);
    });
  });

  group('DebugInWaveCruxDispatcher — waveform file missing', () {
    test('returns waveformMissing when the recorded path no longer exists '
        'on disk (e.g. a passing test whose dump was cleaned up)', () async {
      final container = ProviderContainer(
        overrides: answeredTelemetryOverrides(),
      );
      addTearDown(container.dispose);

      final dispatcher = container.read(debugInWaveCruxDispatcherProvider);
      final result = await dispatcher.dispatch(
        waveformPath: p.join(waveformFile.parent.path, 'was-cleaned-up.vcd'),
      );
      expect(result.outcome, DebugInWaveCruxOutcome.waveformMissing);
    });
  });

  group('DebugInWaveCruxDispatcher — server disabled', () {
    test('returns serverDisabled when CXP is off', () async {
      final container = simcruxCxpRuntimeContainer(
        manifestDirectory: manifests,
        enabled: false,
      );
      expect(await container.read(cruxCxpRuntimeProvider.future), isNull);

      final dispatcher = container.read(debugInWaveCruxDispatcherProvider);
      final result = await dispatcher.dispatch(waveformPath: waveformFile.path);
      expect(result.outcome, DebugInWaveCruxOutcome.serverDisabled);
    });
  });

  group('DebugInWaveCruxDispatcher — no peer', () {
    test('returns noPeer when no WaveCrux peer is connected', () async {
      final container = simcruxCxpRuntimeContainer(
        manifestDirectory: manifests,
      );
      await runningCxpRuntime(container);

      final dispatcher = container.read(debugInWaveCruxDispatcherProvider);
      final result = await dispatcher.dispatch(waveformPath: waveformFile.path);
      expect(result.outcome, DebugInWaveCruxOutcome.noPeer);
    });
  });

  group('DebugInWaveCruxDispatcher — dispatched', () {
    test('dispatches RequestHighlight to a connected WaveCrux peer and '
        'records an outbound cross-probe event', () async {
      final container = simcruxCxpRuntimeContainer(
        manifestDirectory: manifests,
      );
      final runtime = await runningCxpRuntime(container);

      // Connect a fake WaveCrux peer to the server.
      final wavecruxClient = LocalCxpClient(
        selfIdentity: const PeerIdentity(
          peerId: 'wavecrux-fake-99',
          productName: 'wavecrux',
          productVersion: '0.1.0',
        ),
      );
      await wavecruxClient.connect(
        host: '127.0.0.1',
        port: runtime.boundPort!,
        token: cxpProcessAuthToken,
      );
      addTearDown(wavecruxClient.dispose);
      // A receiver that never acks is a wedged receiver: the dispatcher waits
      // for the acknowledgement, because that reply is where CXP §9.4
      // (https://edacrux.app/cxp#sec-9-4) puts
      // "I honoured the element but could not resolve the coordinate".
      addTearDown(autoAckHighlights(wavecruxClient).cancel);

      // Wait for handshake to settle so the runtime's peers include the new
      // wavecrux peer.
      final handshook = await pollUntil(
        () => runtime.peers.any((p) => p.peerId == 'wavecrux-fake-99'),
      );
      expect(handshook, isTrue, reason: 'expected the peer to be connected');

      final received = wavecruxClient.inbound.firstWhere(
        (m) => m.message is RequestHighlight,
      );

      final dispatcher = container.read(debugInWaveCruxDispatcherProvider);
      final result = await dispatcher.dispatch(
        waveformPath: waveformFile.path,
        displayName: 'cpu_unit/test_alu_basic',
        suggestedSignals: const <String>['tb_alu.*'],
      );
      expect(result.outcome, DebugInWaveCruxOutcome.dispatched);
      expect(result.targetPeerId, 'wavecrux-fake-99');

      final inbound = await received.timeout(const Duration(seconds: 2));
      final msg = inbound.message as RequestHighlight;
      expect(msg.element.kind, ElementKind.source);
      expect(msg.element.path, waveformFile.path);

      // The panel's event log captured the outbound RequestHighlight: the
      // runtime records every send, so the dispatcher records none itself.
      final events = container.read(cruxCxpEventLogProvider);
      final outbound = events
          .where(
            (e) =>
                e.direction == CrossProbeEventDirection.outbound &&
                e.kind == CrossProbeEventKind.highlightSent,
          )
          .toList();
      expect(outbound, hasLength(1));
      expect(outbound.single.peerLabel, 'WaveCrux');
      expect(outbound.single.summary, 'cpu_unit/test_alu_basic');
    });

    test('when suggestedSignals is non-empty, a NotifySelection metadata '
        'ping precedes the RequestHighlight', () async {
      final container = simcruxCxpRuntimeContainer(
        manifestDirectory: manifests,
      );
      final runtime = await runningCxpRuntime(container);

      final wavecruxClient = LocalCxpClient(
        selfIdentity: const PeerIdentity(
          peerId: 'wavecrux-fake-100',
          productName: 'wavecrux',
          productVersion: '0.1.0',
        ),
      );
      await wavecruxClient.connect(
        host: '127.0.0.1',
        port: runtime.boundPort!,
        token: cxpProcessAuthToken,
      );
      addTearDown(wavecruxClient.dispose);
      final handshook = await pollUntil(
        () => runtime.peers.any((p) => p.peerId == 'wavecrux-fake-100'),
      );
      expect(handshook, isTrue, reason: 'expected the peer to be connected');

      final received = <CxpClientInbound>[];
      final sub = wavecruxClient.inbound.listen(received.add);
      addTearDown(sub.cancel);
      addTearDown(autoAckHighlights(wavecruxClient).cancel);

      await container
          .read(debugInWaveCruxDispatcherProvider)
          .dispatch(
            waveformPath: waveformFile.path,
            suggestedSignals: const <String>['tb_alu.*', 'tb_alu.dut.flags'],
          );
      // Wait for the *second* of the two messages. Polling only for the
      // NotifySelection proves nothing about the RequestHighlight that
      // follows it — the two cross the socket as separate writes, and
      // asserting on the second one the instant the first lands is a race
      // that a slower loopback (Windows CI) loses.
      final settled = await pollUntil(
        () => received.any((m) => m.message is RequestHighlight),
      );
      expect(
        settled,
        isTrue,
        reason: 'expected the RequestHighlight to reach the peer',
      );
      expect(
        received.any((m) => m.message is NotifySelection),
        isTrue,
        reason: 'expected a NotifySelection ping',
      );
      expect(
        received.indexWhere((m) => m.message is NotifySelection),
        lessThan(received.indexWhere((m) => m.message is RequestHighlight)),
        reason: 'the metadata ping must precede the highlight request',
      );

      final notifies = received
          .where((m) => m.message is NotifySelection)
          .toList();
      expect(notifies, hasLength(1));
      final notify = notifies.single.message as NotifySelection;
      // Metadata round-trips through JSON, so the list comes back as
      // List<dynamic> with String entries. Defensive read keeps the
      // assertion happy regardless of decoder type inference.
      final hint = notify.metadata[kSimcruxSuggestedSignalsKey];
      expect(hint, isA<List<Object?>>());
      expect(
        (hint! as List).cast<String>(),
        <String>['tb_alu.*', 'tb_alu.dut.flags'],
      );

      final highlights = received
          .where((m) => m.message is RequestHighlight)
          .toList();
      expect(highlights, hasLength(1));
    });
  });

  group('DebugInWaveCruxDispatcher — connector-linked peer (production '
      'topology)', () {
    test(
      'dispatches over a real connector-dialed link and the peer '
      'genuinely RECEIVES it on its own server.inbound — trusting '
      'dispatched:true as proof of delivery is the worst CXP failure mode; '
      'this asserts on the PEER product stack instead',
      () async {
        final container = simcruxCxpRuntimeContainer(
          manifestDirectory: manifests,
        );
        final runtime = await runningCxpRuntime(container);

        const waveId = PeerIdentity(
          peerId: 'wavecrux-debug-e2e-1',
          productName: 'wavecrux',
          productVersion: '0.3.0',
        );
        final peer = await CxpFakePeer.start(
          identity: waveId,
          manifestDirectory: manifests.path,
        );
        addTearDown(peer.stop);
        // The real WaveCrux acks every request_highlight, and the dispatcher
        // waits for it. Acking from the peer's OWN server is also what makes
        // the return leg below a genuine round trip.
        addTearDown(autoAckHighlightsFromServer(peer.server).cancel);

        final mutual = await pollUntil(
          () =>
              runtime.peers.any((p) => p.peerId == waveId.peerId) &&
              peer.isConnectedTo(runtime.selfIdentity.peerId),
        );
        expect(
          mutual,
          isTrue,
          reason: 'expected mutual connect before dispatch',
        );

        final result = await container
            .read(debugInWaveCruxDispatcherProvider)
            .dispatch(
              waveformPath: waveformFile.path,
              displayName: 'cpu_unit/test_alu_basic',
              suggestedSignals: const <String>['tb_alu.*'],
            );
        // `dispatched` is only ever the outcome of an acknowledged send, so it
        // also proves the peer's ack routed back into SimCrux over the link.
        expect(result.outcome, DebugInWaveCruxOutcome.dispatched);
        expect(result.targetPeerId, waveId.peerId);

        // THE receipt assertion: not
        // `result.outcome == dispatched`, but that the peer's own
        // product-level inbound stream actually observed the frame.
        final gotRequest = await pollUntil(
          () => peer.received.any((m) => m.message is RequestHighlight),
        );
        expect(
          gotRequest,
          isTrue,
          reason:
              "peer's server.inbound must receive the RequestHighlight "
              '— dispatched:true is not proof of receipt',
        );
        final request = peer.received.firstWhere(
          (m) => m.message is RequestHighlight,
        );
        expect(
          (request.message as RequestHighlight).element.path,
          waveformFile.path,
        );
        expect(request.from.peerId, runtime.selfIdentity.peerId);
      },
    );
  });

  group('DebugInWaveCruxDispatcher — the CXP stream coordinate on the wire', () {
    /// Stands up SimCrux's runtime with one connected fake WaveCrux client and
    /// hands back everything that crossed the socket plus the dispatch result,
    /// so each case below asserts only on the wire.
    ///
    /// The messages are **recorded from before the dispatch**, not awaited
    /// after it: `dispatch` waits for the peer's acknowledgement, so by
    /// the time it returns the request has already been delivered and a
    /// `firstWhere` subscribed afterwards would wait forever.
    ///
    /// [ackHonored] / [ackReason] shape the fake receiver's reply, which is
    /// what the outcome is classified from.
    Future<(LocalCxpClient, List<CxpClientInbound>, DebugInWaveCruxResult)>
    dispatchTo({
      required ProviderContainer container,
      required String peerId,
      TestResult? result,
      bool ackHonored = true,
      String? ackReason,
      Duration ackTimeout = const Duration(seconds: 5),
      bool ack = true,
    }) async {
      final runtime = await runningCxpRuntime(container);
      final client = LocalCxpClient(
        selfIdentity: PeerIdentity(
          peerId: peerId,
          productName: 'wavecrux',
          productVersion: '0.1.0',
        ),
      );
      await client.connect(
        host: '127.0.0.1',
        port: runtime.boundPort!,
        token: cxpProcessAuthToken,
      );
      final handshook = await pollUntil(
        () => runtime.peers.any((p) => p.peerId == peerId),
      );
      expect(handshook, isTrue);
      final received = <CxpClientInbound>[];
      final recorder = client.inbound.listen(received.add);
      addTearDown(recorder.cancel);
      if (ack) {
        addTearDown(
          autoAckHighlights(
            client,
            honored: ackHonored,
            reason: ackReason,
          ).cancel,
        );
      }
      final dispatched = await container
          .read(debugInWaveCruxDispatcherProvider)
          .dispatch(
            waveformPath: waveformFile.path,
            displayName: 'insn_sub_ch0',
            result: result,
            ackTimeout: ackTimeout,
          );
      return (client, received, dispatched);
    }

    ProviderContainer newContainer() =>
        simcruxCxpRuntimeContainer(manifestDirectory: manifests);

    TestResult counterexampleRow() {
      final now = DateTime.utc(2026, 8, 2);
      return TestResult(
        testId: 'insn_sub_ch0',
        runId: 'run-1',
        status: TestStatus.fail,
        startedAt: now,
        finishedAt: now,
        waveformPath: waveformFile.path,
        metrics: const <String, String>{
          RiscvFormalDriver.kMetricVerdict: 'FAIL',
          RiscvFormalDriver.kMetricCheck: 'insn_sub_ch0',
          RiscvFormalDriver.kMetricChannel: 'ch0',
          RiscvFormalDriver.kMetricDepthReached: '7',
        },
      );
    }

    test('a failing bounded proof puts the step on the RequestHighlight, '
        'not only on the courtesy NotifySelection', () async {
      // The imperative message is the one the receiver must act on. A peer
      // that dropped the notify and honoured only the highlight would
      // otherwise land at time zero believing it had done as asked.
      final container = newContainer();
      final (client, received, result) = await dispatchTo(
        container: container,
        result: counterexampleRow(),
        peerId: 'wavecrux-coord-1',
      );
      addTearDown(client.dispose);
      expect(result.outcome, DebugInWaveCruxOutcome.dispatched);

      final msg =
          received.firstWhere((m) => m.message is RequestHighlight).message
              as RequestHighlight;
      expect(msg.coordinate, isNotNull);
      expect(
        msg.coordinate!.streamId,
        CxpStreamCoordinate.riscvFormalTraceStepStreamId,
      );
      expect(msg.coordinate!.sequenceIndex, 7);
      expect(msg.coordinate!.subId, 'ch0');
      // And it is reported back to the caller, so a UI can say whether the
      // hand-off was precise or only file-level.
      expect(result.coordinate, equals(msg.coordinate));
    });

    test('a row that cannot state an index sends no coordinate, and the '
        'file-level hand-off is unchanged', () async {
      final now = DateTime.utc(2026, 8, 2);
      final container = newContainer();
      final (client, received, result) = await dispatchTo(
        container: container,
        result: TestResult(
          testId: 'alu_basic',
          runId: 'run-1',
          status: TestStatus.fail,
          startedAt: now,
          finishedAt: now,
          waveformPath: waveformFile.path,
        ),
        peerId: 'wavecrux-coord-2',
      );
      addTearDown(client.dispose);
      final msg =
          received.firstWhere((m) => m.message is RequestHighlight).message
              as RequestHighlight;
      expect(msg.coordinate, isNull);
      expect(msg.element.path, waveformFile.path);
      expect(result.outcome, DebugInWaveCruxOutcome.dispatched);
      expect(result.coordinate, isNull);
    });

    test('a caller that passes no result at all still dispatches — the '
        'coordinate is additive to every existing call site', () async {
      final container = newContainer();
      final (client, received, result) = await dispatchTo(
        container: container,
        peerId: 'wavecrux-coord-3',
      );
      addTearDown(client.dispose);
      final msg =
          received.firstWhere((m) => m.message is RequestHighlight).message
              as RequestHighlight;
      expect(msg.coordinate, isNull);
      expect(result.outcome, DebugInWaveCruxOutcome.dispatched);
    });
  });

  group("DebugInWaveCruxDispatcher — the receiver's acknowledgement", () {
    /// **The bug this group exists for.**
    ///
    /// WaveCrux answers a coordinate it cannot resolve with `honored: true`
    /// plus a `reason` — CXP §9.4's "I opened your file, here is what I could
    /// not do". SimCrux sent the request fire-and-forget, never read the
    /// reply, and reported "Sent to WaveCrux." So the flagship counterexample
    /// hand-off opened a trace, landed nowhere, and said nothing: a silent
    /// no-op assembled out of two halves that each behaved correctly.
    ///
    /// MUTATION: go back to `sendTo` for the request_highlight, or collapse
    /// `dispatchedWithLimitation` into `dispatched`, and these go red.
    Future<DebugInWaveCruxResult> dispatchWithAck({
      required String peerId,
      bool ackHonored = true,
      String? ackReason,
      bool ack = true,
      Duration ackTimeout = const Duration(seconds: 5),
    }) async {
      final container = simcruxCxpRuntimeContainer(
        manifestDirectory: manifests,
      );
      final runtime = await runningCxpRuntime(container);
      final client = LocalCxpClient(
        selfIdentity: PeerIdentity(
          peerId: peerId,
          productName: 'wavecrux',
          productVersion: '0.1.0',
        ),
      );
      await client.connect(
        host: '127.0.0.1',
        port: runtime.boundPort!,
        token: cxpProcessAuthToken,
      );
      addTearDown(client.dispose);
      final handshook = await pollUntil(
        () => runtime.peers.any((p) => p.peerId == peerId),
      );
      expect(handshook, isTrue);
      if (ack) {
        addTearDown(
          autoAckHighlights(
            client,
            honored: ackHonored,
            reason: ackReason,
          ).cancel,
        );
      }
      return await container
          .read(debugInWaveCruxDispatcherProvider)
          .dispatch(
            waveformPath: waveformFile.path,
            displayName: 'insn_sub_ch0',
            ackTimeout: ackTimeout,
          );
    }

    test('an honoured ack carrying a reason is NOT reported as a clean '
        'success, and the reason survives to the caller', () async {
      const declined =
          'the loaded trace has no uniform step grid, so a bounded-proof '
          'step cannot be converted to a time';
      final result = await dispatchWithAck(
        peerId: 'wavecrux-ack-partial',
        ackReason: declined,
      );
      expect(result.outcome, DebugInWaveCruxOutcome.dispatchedWithLimitation);
      // Verbatim: only the receiver knows what it found in the trace, so the
      // string is passed through rather than mapped onto a local message.
      expect(result.reason, declined);
    });

    test('an ack with no reason is a clean success', () async {
      final result = await dispatchWithAck(peerId: 'wavecrux-ack-clean');
      expect(result.outcome, DebugInWaveCruxOutcome.dispatched);
      expect(result.reason, isNull);
    });

    test('an empty reason is treated as no reason', () async {
      // A peer that sets `reason: ""` has said nothing; showing the user an
      // empty explanation would be worse than the plain success it is.
      final result = await dispatchWithAck(
        peerId: 'wavecrux-ack-empty',
        ackReason: '',
      );
      expect(result.outcome, DebugInWaveCruxOutcome.dispatched);
    });

    test(
      'honored:false is reported as rejected, with the peer’s reason',
      () async {
        final result = await dispatchWithAck(
          peerId: 'wavecrux-ack-refused',
          ackHonored: false,
          ackReason: 'wavecrux opens only waveform artifacts',
        );
        expect(result.outcome, DebugInWaveCruxOutcome.rejected);
        expect(result.reason, 'wavecrux opens only waveform artifacts');
      },
    );

    test(
      'a peer that never acks is unacknowledged, never dispatched',
      () async {
        final result = await dispatchWithAck(
          peerId: 'wavecrux-ack-mute',
          ack: false,
          ackTimeout: const Duration(milliseconds: 200),
        );
        expect(result.outcome, DebugInWaveCruxOutcome.unacknowledged);
        expect(result.reason, isNull);
      },
    );
  });
}
