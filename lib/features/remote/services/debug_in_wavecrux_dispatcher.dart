// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';
import 'package:simcrux/domain/models/formal_result_summary.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/features/remote/services/cxp_workspace_link.dart';
import 'package:simcrux/services/remote/cxp/formal_stream_coordinate.dart';
import 'package:simcrux/services/telemetry/formal_telemetry.dart';

/// Product short-name string WaveCrux peers announce in their
/// [PeerIdentity.productName]. Hardcoded by convention — every
/// product uses its lowercased short-name.
const String wavecruxProductName = 'wavecrux';

/// Metadata key SimCrux uses to attach suggested signal names to the
/// RequestHighlight metadata blob. WaveCrux honours unknown metadata
/// keys (per the v1 spec), so the suggestion
/// payload is forward-compatible regardless of whether WaveCrux's
/// receive side has implemented the convention yet.
const String kSimcruxSuggestedSignalsKey = 'simcrux.suggested_signals';

/// Outcome of a "Debug in WaveCrux" dispatch attempt.
enum DebugInWaveCruxOutcome {
  /// Dispatched to a connected WaveCrux peer, which acknowledged it acted on
  /// the whole request.
  dispatched,

  /// Delivered, and the peer honoured the element — the trace opened — but it
  /// reported something it could not do, and said why in
  /// [DebugInWaveCruxResult.reason].
  ///
  /// This is the outcome a stream coordinate the receiver cannot resolve
  /// produces (CXP §9.4, https://edacrux.app/cxp#sec-9-4: *honour the
  /// element, say so in the ack's `reason`*).
  /// **It must reach the user.** A cross-probe that opens the right file and
  /// then quietly fails to land where it promised is indistinguishable, from
  /// the outside, from a broken feature — which is exactly how the RISC-V
  /// counterexample hand-off read for as long as this enum had nowhere to put
  /// an honoured ack's reason.
  dispatchedWithLimitation,

  /// Delivered, and the peer replied that it could not act on the request at
  /// all. [DebugInWaveCruxResult.reason] carries its explanation when it gave
  /// one.
  rejected,

  /// Delivered, and no acknowledgement came back before the wait expired. The
  /// peer may be wedged, or old enough not to ack; either way the caller
  /// cannot claim the hand-off landed.
  unacknowledged,

  /// No WaveCrux peer is currently connected. Caller surfaces a
  /// snackbar / dialog explaining how to launch one.
  noPeer,

  /// The CXP server is not running (disabled in settings). Caller
  /// surfaces a snackbar pointing at Settings → CXP Cross-Probe.
  serverDisabled,

  /// The test result does not have a waveform path captured. Caller
  /// surfaces a hint that the test needs to re-run with waveform
  /// capture enabled.
  noWaveform,

  /// A waveform path was recorded but the file no longer exists on disk
  /// (e.g. the passing-waveform archive entry was pruned, or a failing
  /// test's retained dir was swept). Caller surfaces a hint to re-run the
  /// test so the dump is regenerated. Distinct from [noWaveform] (never
  /// captured) so the message can say "was cleaned up", not "enable capture".
  waveformMissing,
}

/// Result + diagnostic context returned by the dispatcher.
@immutable
class DebugInWaveCruxResult {
  /// Creates a result envelope.
  const DebugInWaveCruxResult({
    required this.outcome,
    this.targetPeerId,
    this.waveformPath,
    this.coordinate,
    this.reason,
  });

  /// What happened.
  final DebugInWaveCruxOutcome outcome;

  /// PeerIdentity.peerId of the target WaveCrux peer when
  /// [outcome] is [DebugInWaveCruxOutcome.dispatched]; null
  /// otherwise.
  final String? targetPeerId;

  /// The waveform file path SimCrux attempted to dispatch.
  final String? waveformPath;

  /// The CXP semantic stream coordinate (CXP §9.9,
  /// https://edacrux.app/cxp#sec-9-9) that rode along, or null when
  /// the result could not honestly state one. Exposed so callers and tests
  /// can see *whether* the hand-off was precise without re-deriving it, and
  /// so a "could not point at the failure, only at the file" affordance has
  /// something to read.
  final CxpStreamCoordinate? coordinate;

  /// The peer's own explanation, verbatim, when it gave one — the `reason`
  /// field of its `request_highlight_ack`.
  ///
  /// Set for [DebugInWaveCruxOutcome.dispatchedWithLimitation] and usually for
  /// [DebugInWaveCruxOutcome.rejected]. It is written by the *receiver* and
  /// describes the receiver's situation ("the loaded trace has no uniform step
  /// grid…"), which is why it is passed through to the user rather than
  /// mapped onto a local string: no message SimCrux could compose from here
  /// would know what WaveCrux found in the file.
  final String? reason;
}

/// Service that originates "Debug in WaveCrux" CXP messages.
///
/// Wraps the v1 vocabulary trick documented in
/// [SimCruxNameResolver]: a [RequestHighlight] with an
/// [ElementKind.source] payload whose path looks like a waveform file
/// (the receiver inspects the extension). Suggested signal names are
/// attached via a `metadata` blob entry (`simcrux.suggested_signals`)
/// that WaveCrux's RequestHighlight handler may consume as a hint.
class DebugInWaveCruxDispatcher {
  /// Constructs a dispatcher bound to [ref].
  DebugInWaveCruxDispatcher({required this.ref});

  /// Riverpod ref used to read the CXP runtime and the connected
  /// peer list.
  final Ref ref;

  /// Look up the first connected WaveCrux peer, or null.
  ///
  /// "Connected" means [runtime] holds a live link to it: the peer is
  /// running and we can send to it. A stale manifest from a previous run is
  /// never in the list.
  ///
  /// Read from the runtime rather than the peer-list provider, which is a
  /// stream that only has a value while something watches it (the toolbar
  /// badge does, a headless call does not), and screened by the same filter
  /// every cross-probe surface uses.
  String? _findWaveCruxPeerId(CruxCxpRuntime runtime) {
    final allowed = ref.read(cruxCxpPeerFilterProvider);
    for (final peer in runtime.peers) {
      if (peer.productName == wavecruxProductName && allowed(peer)) {
        return peer.peerId;
      }
    }
    return null;
  }

  /// Dispatch a "Debug in WaveCrux" request.
  ///
  /// - [waveformPath] is the captured waveform file path the test
  ///   produced. When null or empty, returns
  ///   [DebugInWaveCruxOutcome.noWaveform].
  /// - [suggestedSignals] is an optional list of signal names SimCrux
  ///   would like WaveCrux to add to the viewer. Carried as a
  ///   metadata hint per [kSimcruxSuggestedSignalsKey]; receivers
  ///   that don't recognise the key ignore it (forward compatible).
  /// - [displayName] is a human-friendly label (typically the test
  ///   id) for the cross-probe-panel summary on both ends.
  /// - [result] is the row being handed off, when the caller has it. Its
  ///   only use here is [riscvStreamCoordinateFor]: a failing bounded proof
  ///   yields a CXP §9.9 coordinate that turns "open this trace" into "open
  ///   this trace at the step the assertion fired". Omitting it, or passing
  ///   a row that cannot state a coordinate, degrades to exactly the
  ///   file-level hand-off that shipped before — never to an error.
  /// - [ackTimeout] bounds the wait for the receiver's acknowledgement.
  ///   Exceeding it is [DebugInWaveCruxOutcome.unacknowledged], never a
  ///   claimed success.
  ///
  /// ## Why this awaits the acknowledgement
  ///
  /// The `request_highlight` goes out through the **acked** send, not the
  /// fire-and-forget one, and the reply's `reason` is carried back in
  /// [DebugInWaveCruxResult.reason]. CXP §9.4
  /// (https://edacrux.app/cxp#sec-9-4) requires a receiver that
  /// honours the element but cannot resolve the coordinate to say so in the
  /// ack rather than fail; that contract only means anything if the
  /// originating app reads the ack. It did not, and the RISC-V counterexample
  /// hand-off spent its whole life reporting "Sent to WaveCrux." while
  /// WaveCrux was replying, correctly and in detail, that it could not land.
  ///
  /// [partition] is the EQY partition whose trace [waveformPath] is, when the
  /// hand-off is one partition of an equivalence row: its coordinate carries
  /// the partition as `sub_id` (CXP §9.9.3), one cross-probe per partition.
  Future<DebugInWaveCruxResult> dispatch({
    required String? waveformPath,
    String? displayName,
    List<String> suggestedSignals = const <String>[],
    String? designId,
    String? topModule,
    TestResult? result,
    FormalPartitionRow? partition,
    Duration ackTimeout = const Duration(seconds: 5),
  }) async {
    final outcome = await _dispatch(
      waveformPath: waveformPath,
      displayName: displayName,
      suggestedSignals: suggestedSignals,
      designId: designId,
      topModule: topModule,
      result: result,
      partition: partition,
      ackTimeout: ackTimeout,
    );
    // **Every** return path is counted, which is why the body moved into
    // `_dispatch` and this wrapper exists at all: the flagship suite-funnel
    // metric is a *funnel*, and a funnel that only counted its successes would
    // report a healthy conversion rate on a feature that never once reached a
    // peer. `noWaveform` and `serverDisabled` are the two most interesting
    // rows in it.
    //
    // The outcome enum is the only thing recorded. The waveform path, the
    // peer id, the display name (a test id) and the peer's verbatim `reason`
    // string are all present at this point and none of them leave the machine.
    ref
        .read(telemetryServiceProvider)
        .record(
          TelemetryEvent(
            'debug_in_wavecrux.used',
            properties: <String, Object?>{
              'outcome': telemetryEnumToken(outcome.outcome),
              // Which kind of row: a counterexample and a simulation dump
              // ride the same hand-off. A token, never the row.
              'origin': debugInWaveCruxOrigin(result),
            },
          ),
        );
    return outcome;
  }

  Future<DebugInWaveCruxResult> _dispatch({
    required String? waveformPath,
    required String? displayName,
    required List<String> suggestedSignals,
    required String? designId,
    required String? topModule,
    required TestResult? result,
    required FormalPartitionRow? partition,
    required Duration ackTimeout,
  }) async {
    if (waveformPath == null || waveformPath.isEmpty) {
      return DebugInWaveCruxResult(
        outcome: DebugInWaveCruxOutcome.noWaveform,
        waveformPath: waveformPath,
      );
    }
    // Guard against handing WaveCrux a path that no longer exists — it would
    // otherwise surface a raw PathNotFoundException. A passing test's dump is
    // relocated into the durable archive at run time, but a result loaded from
    // a prior session (or an archive entry since pruned) can still dangle.
    if (!File(waveformPath).existsSync()) {
      return DebugInWaveCruxResult(
        outcome: DebugInWaveCruxOutcome.waveformMissing,
        waveformPath: waveformPath,
      );
    }
    final runtime = ref.read(cruxCxpRuntimeProvider).value;
    if (runtime == null || !runtime.isAvailable) {
      return DebugInWaveCruxResult(
        outcome: DebugInWaveCruxOutcome.serverDisabled,
        waveformPath: waveformPath,
      );
    }
    // Shared-workspace producer: register the dump we are handing off in the shared
    // workspace under the design's INPUT-dir design_id, so the reverse
    // cross-probe (WaveCrux → SimCrux) — and a WaveCrux with nothing open —
    // can resolve this VCD. Belt-and-suspenders with the on-produce upsert in
    // the regression runner: this covers a session that only loaded results.
    if (designId != null) {
      unawaited(
        publishWaveformWorkspaceArtifact(
          ref,
          designId: designId,
          waveformPath: waveformPath,
          topModule: topModule,
        ),
      );
    }
    final peerId = _findWaveCruxPeerId(runtime);
    if (peerId == null) {
      return DebugInWaveCruxResult(
        outcome: DebugInWaveCruxOutcome.noPeer,
        waveformPath: waveformPath,
      );
    }
    final element = ElementId(
      kind: ElementKind.source,
      path: waveformPath,
    );
    // The CXP stream coordinate. Derived after the existence check above, so a
    // coordinate is never sent alongside a path the receiver cannot open —
    // CXP §9.9's (https://edacrux.app/cxp#sec-9-9)
    // "absence beats approximation" has a filesystem half as well as an
    // arithmetic one. Null for every row that cannot state an index, which
    // is most of them; see [formalStreamCoordinateFor]: a RISC-V check's
    // `riscv.formal.trace_step`, or an `sby` or EQY counterexample's
    // `formal.trace_step`.
    final coordinate = result == null
        ? null
        : formalStreamCoordinateFor(result, partition: partition);
    // The registered `formal.` keys: the property's role and label, or an
    // EQY run's gold and gate scopes, so WaveCrux can arrange the miter.
    final formal = result == null
        ? const <String, Object?>{}
        : formalHandoffMetadata(result);
    // Wrap suggested signals in a RequestHighlight-compatible message. v1
    // RequestHighlight does not carry metadata in its payload directly — we
    // route through NotifySelection's metadata blob first (a courtesy ping
    // carrying the hint) and then send the imperative RequestHighlight. Two-
    // message dispatch keeps us strictly within v1 vocabulary; receivers that
    // ignore the notify_selection metadata still honour the highlight request.
    //
    // The notify_selection also carries `crux.design_id` so a receiver
    // with no matching waveform open can resolve and open this design's dump
    // — attached for consistency with the shared-workspace join even though
    // this forward handoff already names the VCD path directly.
    final metadata = <String, Object?>{
      if (suggestedSignals.isNotEmpty)
        kSimcruxSuggestedSignalsKey: List<String>.unmodifiable(
          suggestedSignals,
        ),
      ...formal,
      cxpDesignIdMetadataKey: ?designId,
    };
    if (metadata.isNotEmpty || coordinate != null) {
      runtime.sendTo(
        peerId,
        NotifySelection(
          elements: <ElementId>[element],
          displayName: displayName,
          coordinate: coordinate,
          metadata: metadata,
        ),
      );
    }
    // The coordinate rides the imperative message too, not only the courtesy
    // ping. `request_highlight` is the one the receiver must act on, and a
    // receiver that dropped the notify (unsubscribed, raced, or simply does
    // not implement §9.9's notify path) would otherwise land at time zero
    // while believing it had honoured the request.
    //
    // Sent through the ACKED form: the reply is the only channel on which a
    // receiver can say "I opened your trace but could not land on step 7, and
    // here is why", and a hand-off that throws that away is a hand-off that
    // cannot tell a success from a silent miss.
    //
    // The runtime records the send in the panel's event log.
    final reply = await runtime.requestHighlight(
      peerId,
      RequestHighlight(
        element: element,
        coordinate: coordinate,
        metadata: <String, Object?>{
          ...formal,
          cxpDesignIdMetadataKey: ?designId,
        },
      ),
      timeout: ackTimeout,
      summary: displayName ?? waveformPath,
    );
    if (!reply.delivered) {
      return DebugInWaveCruxResult(
        outcome: DebugInWaveCruxOutcome.noPeer,
        waveformPath: waveformPath,
      );
    }
    // Past `delivered`, so a peer that was unreachable is an attempt, not a
    // cross-probe. A missing ack is a timeout — the peer never said yes, so it
    // counts as not honored, the same as an explicit refusal. Identical rule,
    // and identical wording, to WaveCrux's outbound site: the two ends of the
    // same funnel have to agree on what they are counting.
    //
    // This is the **only** outbound `cxp.crossprobe` SimCrux records. The Pro
    // overlay's `CrossProbeOriginator` uses the fire-and-forget `sendTo`, so
    // it has no ack to read and cannot state `honored` at all — and reporting
    // `honored: false` for "we never asked" would be worse than reporting
    // nothing, because it is indistinguishable from a peer that refused.
    ref
        .read(telemetryServiceProvider)
        .record(
          TelemetryEvent(
            'cxp.crossprobe',
            properties: <String, Object?>{
              'direction': 'outbound',
              'honored': reply.ack?.honored ?? false,
            },
          ),
        );
    return DebugInWaveCruxResult(
      outcome: _outcomeForAck(reply.ack),
      targetPeerId: peerId,
      waveformPath: waveformPath,
      coordinate: coordinate,
      reason: reply.ack?.reason,
    );
  }

  /// Classifies a `request_highlight_ack`.
  ///
  /// The distinction the whole fix turns on is between the first two lines: an
  /// ack that is honoured **and** carries a reason is not a plain success. CXP
  /// §9.4 uses exactly that shape for "I did what I could, and here is what I
  /// could not do", and it is the shape WaveCrux replies with when a §9.9
  /// stream coordinate does not resolve against the trace it just opened.
  static DebugInWaveCruxOutcome _outcomeForAck(RequestHighlightAck? ack) {
    if (ack == null) return DebugInWaveCruxOutcome.unacknowledged;
    if (!ack.honored) return DebugInWaveCruxOutcome.rejected;
    final reason = ack.reason;
    if (reason != null && reason.isNotEmpty) {
      return DebugInWaveCruxOutcome.dispatchedWithLimitation;
    }
    return DebugInWaveCruxOutcome.dispatched;
  }
}

/// Provider exposing the dispatcher. Construction is cheap — every
/// inspector action gets a fresh ref-bound instance.
final Provider<DebugInWaveCruxDispatcher> debugInWaveCruxDispatcherProvider =
    Provider<DebugInWaveCruxDispatcher>(
      (ref) => DebugInWaveCruxDispatcher(ref: ref),
    );

/// Extract suggested signals from a [TestSpec] when present.
///
/// SimCrux's test config schema does not yet expose a
/// `signals_of_interest:` field. Absent that field, the dispatcher reads the top module name and
/// returns a small heuristic list (`<top>.*`) — handy when the user
/// has not yet curated their own list and at worst is silently
/// ignored by WaveCrux's RequestHighlight handler.
///
/// Lives on the dispatcher as a static helper rather than the
/// caller's responsibility so the heuristic stays in one place.
List<String> deriveSuggestedSignalsFromTopModule(String? topModule) {
  if (topModule == null || topModule.isEmpty) return const <String>[];
  // A receiver that interprets the list as glob patterns picks up
  // every signal under the top module's scope. Inert otherwise.
  return <String>['$topModule.*'];
}
