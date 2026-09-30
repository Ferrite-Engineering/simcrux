// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_cxp_ui/crux_cxp_ui.dart' as cxp_ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/remote/providers/cross_probe_events_provider.dart';
import 'package:simcrux/features/remote/providers/cross_probe_originate_gate_provider.dart';
import 'package:simcrux/features/remote/providers/cross_probe_visibility_provider.dart';
import 'package:simcrux/features/remote/providers/cxp_discovery_provider.dart';
import 'package:simcrux/features/remote/providers/cxp_server_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/remote/cxp/simcrux_cxp_server.dart';

/// SimCrux's docked cross-probe panel.
///
/// A thin `ConsumerStatefulWidget` host around the shared
/// `crux_cxp_ui.CrossProbePanel`: it owns a [SimCruxCrossProbePanelController]
/// that bridges SimCrux's live CXP Riverpod state into the panel's reactive
/// contract, and disposes it with the widget. SimCrux's old modal `Dialog`
/// presentation of the panel is retired in favour of this docked side-panel,
/// which [RegressionTabContent] swaps into the right of the IDE layout when
/// `crossProbeVisibleProvider` is set.
///
/// The shared widget is *also* named `CrossProbePanel`, so it is imported with
/// the `cxp_ui` prefix and this host is named distinctly.
class SimCruxCrossProbePanel extends ConsumerStatefulWidget {
  /// Creates the docked cross-probe panel.
  const SimCruxCrossProbePanel({super.key});

  @override
  ConsumerState<SimCruxCrossProbePanel> createState() =>
      _SimCruxCrossProbePanelState();
}

class _SimCruxCrossProbePanelState
    extends ConsumerState<SimCruxCrossProbePanel> {
  late final SimCruxCrossProbePanelController _controller;

  @override
  void initState() {
    super.initState();
    _controller = SimCruxCrossProbePanelController(ref);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    return cxp_ui.CrossProbePanel(
      controller: _controller,
      // Docked as a CruxDock tab: the strip already carries the icon, the
      // label and the ×, so the panel's own header would duplicate all
      // three directly underneath.
      showHeader: false,
      strings: cxp_ui.CrossProbePanelStrings(
        title: l10n.crossProbePanelTitle,
        closeTooltip: l10n.crossProbeCloseTooltip,
        serverOffline: l10n.crossProbeServerOffline,
        peersSectionTitle: l10n.crossProbeSectionPeers,
        noPeers: l10n.crossProbeNoPeers,
        sendTooltip: l10n.crossProbeSendTooltip,
        unreachableSectionTitle: l10n.crossProbeUnreachableTitle,
        eventsSectionTitle: l10n.crossProbeSectionEvents,
        noEvents: l10n.crossProbeNoEvents,
        clearEventsLabel: l10n.crossProbeClearEvents,
        // The peer's reason arrives in the peer's own words; only the frame
        // around it is ours to translate.
        sendRejected: (peer, reason) => reason == null || reason.isEmpty
            ? l10n.crossProbeSendFailed(peer)
            : l10n.crossProbeSendRefused(peer, reason),
      ),
    );
  }
}

/// Adapts SimCrux's live CXP Riverpod state onto the app-agnostic
/// [cxp_ui.CrossProbePanelController] the shared panel renders against.
///
/// Bridges four reactive sources into the four [ValueListenable]s the panel
/// wraps in `ValueListenableBuilder`s — via `ref.listenManual(...,
/// fireImmediately: true)`:
///
/// * `cxpPeersProvider` (SimCrux stores [CxpPeerManifest]s) → foreign peers'
///   [PeerIdentity]s.
/// * `crossProbeEventsProvider` (SimCrux's per-app [CrossProbeEvent]) mapped to
///   the shared [cxp_ui.CrossProbeEvent] superset.
/// * `cxpDialFailuresProvider` → the unreachable-peers surface.
/// * `cxpServerProvider`'s running-ness → the offline banner.
///
/// and routes the panel's commands back into SimCrux: [onSendTo] sends the
/// selected test to the chosen peer tagged with the reverse-flow
/// `crux.design_id` metadata; [onOpenPanel]/[onClose] toggle
/// `crossProbeVisibleProvider`; [onClearEvents] empties the event buffer.
class SimCruxCrossProbePanelController
    implements cxp_ui.CrossProbePanelController {
  /// Creates a controller bound to [_ref] (the host widget's `ref`). Wires the
  /// reactive bridges immediately.
  SimCruxCrossProbePanelController(this._ref) {
    _peersSub = _ref.listenManual<List<CxpPeerManifest>>(
      cxpPeersProvider,
      (_, next) => _peers.value = _foreignIdentities(next),
      fireImmediately: true,
    );
    _unreachableSub = _ref.listenManual<List<CxpDialFailure>>(
      cxpDialFailuresProvider,
      (_, next) => _unreachable.value = next,
      fireImmediately: true,
    );
    _runningSub = _ref.listenManual<AsyncValue<SimCruxCxpServer?>>(
      cxpServerProvider,
      (_, next) => _serverRunning.value = next.value != null,
      fireImmediately: true,
    );
    _eventsSub = _ref.listenManual<List<CrossProbeEvent>>(
      crossProbeEventsProvider,
      (_, next) => _events.value = next.map(_toSharedEvent).toList(),
      fireImmediately: true,
    );
  }

  final WidgetRef _ref;

  final ValueNotifier<List<PeerIdentity>> _peers =
      ValueNotifier<List<PeerIdentity>>(const <PeerIdentity>[]);
  final ValueNotifier<List<cxp_ui.CrossProbeEvent>> _events =
      ValueNotifier<List<cxp_ui.CrossProbeEvent>>(
        const <cxp_ui.CrossProbeEvent>[],
      );
  final ValueNotifier<List<CxpDialFailure>> _unreachable =
      ValueNotifier<List<CxpDialFailure>>(const <CxpDialFailure>[]);
  final ValueNotifier<bool> _serverRunning = ValueNotifier<bool>(false);

  ProviderSubscription<List<CxpPeerManifest>>? _peersSub;
  ProviderSubscription<List<CrossProbeEvent>>? _eventsSub;
  ProviderSubscription<List<CxpDialFailure>>? _unreachableSub;
  ProviderSubscription<AsyncValue<SimCruxCxpServer?>>? _runningSub;

  /// Set by [dispose]. A send awaits its ack for up to five seconds, and the
  /// panel can close in that window, taking the host widget's `ref` and this
  /// controller's notifiers with it.
  bool _disposed = false;

  @override
  ValueListenable<List<PeerIdentity>> get peers => _peers;

  @override
  ValueListenable<List<cxp_ui.CrossProbeEvent>> get events => _events;

  @override
  ValueListenable<List<CxpDialFailure>> get unreachable => _unreachable;

  @override
  ValueListenable<bool> get serverRunning => _serverRunning;

  @override
  ValueListenable<cxp_ui.CrossProbeSendFailure?> get sendFailure =>
      _sendFailure;

  final ValueNotifier<cxp_ui.CrossProbeSendFailure?> _sendFailure =
      ValueNotifier<cxp_ui.CrossProbeSendFailure?>(null);

  @override
  void onSendTo(PeerIdentity peer) => unawaited(_sendTo(peer));

  /// Sends the selected test to [peer] as an ack-bearing `request_highlight`
  /// then surfaces an undelivered or rejected send as a panel toast — a send
  /// is never a silent no-op. The automatic emitter still broadcasts fire-and-forget
  /// `notify_selection`; the explicit panel send is directed and wants
  /// confirmation, so it uses the acked form.
  ///
  /// Origination is a Pro capability, and this button is a route to it that
  /// ships in open core — so the tier is checked HERE, first, before the
  /// server or the selection is resolved. A denied press has already been
  /// explained by the gate; an unselected test after an admitted press is
  /// the existing quiet no-op, which is a different situation from a
  /// refusal.
  Future<void> _sendTo(PeerIdentity peer) async {
    if (!_ref.read(crossProbeOriginateGateProvider)(_ref.context)) return;
    final server = _ref.read(cxpServerProvider).value;
    if (server == null) return;
    final testId = _ref.read(selectedTestIdProvider);
    if (testId == null || testId.isEmpty) return;
    final config = _ref.read(activeConfigProvider);
    final designId = config == null
        ? null
        : cxpDesignIdForPath(config.projectFilePath);
    final result = await server.requestHighlight(
      peer.peerId,
      RequestHighlight(
        element: ElementId(kind: ElementKind.test, path: testId),
        metadata: <String, Object?>{cxpDesignIdMetadataKey: ?designId},
      ),
    );
    // The panel closed while the ack was pending: there is no one left to
    // tell, and the host's `ref` throws once its widget is gone.
    if (_disposed) return;
    final peerLabel = peer.productName.isEmpty ? peer.peerId : peer.productName;
    if (!result.delivered) {
      // The peer went away between the panel listing it and the send. The
      // user pressed a button; saying nothing would look like it worked.
      _reportSendFailure(cxp_ui.CrossProbeSendFailure(peerLabel: peerLabel));
      return;
    }
    _ref
        .read(crossProbeEventsProvider.notifier)
        .record(
          CrossProbeEvent(
            timestamp: DateTime.now(),
            direction: CrossProbeDirection.outbound,
            kind: CxpMessageKind.requestHighlight,
            peerId: peer.peerId,
            summary: testId,
          ),
        );
    final ack = result.ack;
    // An ack that is honoured AND carries a reason is not a clean success:
    // CXP §9.4 (https://edacrux.app/cxp#sec-9-4) uses exactly that shape for "I did what I could, and here is
    // what I could not do". Treating it as success is how a partly-honoured
    // cross-probe becomes a silent no-op — the receiver explained itself and
    // nothing on this side ever looked.
    final reason = ack?.reason;
    if (ack == null || !ack.honored || (reason != null && reason.isNotEmpty)) {
      _reportSendFailure(
        cxp_ui.CrossProbeSendFailure(peerLabel: peerLabel, reason: reason),
      );
    }
  }

  /// Publishes [failure] for the panel to toast. A failure equal to the last
  /// one would not notify the panel's listener, so a second failed send to
  /// the same peer would be silent; clearing first makes every one count.
  void _reportSendFailure(cxp_ui.CrossProbeSendFailure failure) {
    _sendFailure
      ..value = null
      ..value = failure;
  }

  @override
  void onOpenPanel() =>
      _ref.read(crossProbeVisibleProvider.notifier).set(visible: true);

  @override
  void onClose() =>
      _ref.read(crossProbeVisibleProvider.notifier).set(visible: false);

  @override
  void onClearEvents() => _ref.read(crossProbeEventsProvider.notifier).clear();

  /// Releases the bridge subscriptions and backing notifiers.
  void dispose() {
    _disposed = true;
    _peersSub?.close();
    _eventsSub?.close();
    _unreachableSub?.close();
    _runningSub?.close();
    _peers.dispose();
    _events.dispose();
    _unreachable.dispose();
    _serverRunning.dispose();
    _sendFailure.dispose();
  }

  /// Foreign peers only (never SimCrux's own manifest), as [PeerIdentity]s the
  /// shared panel renders and sends to.
  static List<PeerIdentity> _foreignIdentities(
    List<CxpPeerManifest> manifests,
  ) => <PeerIdentity>[
    for (final m in manifests)
      if (m.identity.productName != simcruxCxpProductName) m.identity,
  ];

  /// Maps a SimCrux [CrossProbeEvent] onto the shared, richer
  /// [cxp_ui.CrossProbeEvent] — folding the wire `kind` + direction into the
  /// panel's semantic categories (including the selection-received
  /// and open-artifact rows the per-app log never modelled).
  cxp_ui.CrossProbeEvent _toSharedEvent(CrossProbeEvent e) {
    final outbound = e.direction == CrossProbeDirection.outbound;
    final direction = outbound
        ? cxp_ui.CrossProbeEventDirection.outbound
        : cxp_ui.CrossProbeEventDirection.inbound;
    final kind = switch (e.kind) {
      CxpMessageKind.notifySelection =>
        outbound
            ? cxp_ui.CrossProbeEventKind.selectionSent
            : cxp_ui.CrossProbeEventKind.selectionReceived,
      CxpMessageKind.requestHighlight =>
        outbound
            ? cxp_ui.CrossProbeEventKind.highlightSent
            : cxp_ui.CrossProbeEventKind.highlightReceived,
      CxpMessageKind.requestOpenArtifact ||
      CxpMessageKind.requestOpenArtifactAck =>
        cxp_ui.CrossProbeEventKind.openArtifact,
      _ => cxp_ui.CrossProbeEventKind.other,
    };
    return cxp_ui.CrossProbeEvent(
      kind: kind,
      direction: direction,
      peerLabel: e.peerId,
      timestamp: e.timestamp,
      summary: e.summary,
      messageKind: e.kind,
    );
  }
}
