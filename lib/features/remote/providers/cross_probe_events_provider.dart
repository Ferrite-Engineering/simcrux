// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_cxp/crux_cxp.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/remote/providers/cxp_server_provider.dart';
import 'package:simcrux/services/remote/cxp/simcrux_cxp_server.dart';

/// Maximum number of cross-probe events the rolling buffer retains.
/// Older events fall off as new ones arrive — sized for the panel's
/// "last activity" pane, not for audit.
const int kCrossProbeEventBufferSize = 50;

/// Rolling buffer of the last ~50 cross-probe events (inbound +
/// outbound). Consumed by the cross-probe panel and instrumented by
/// the notify_selection emitters and inbound request handlers.
final NotifierProvider<CrossProbeEventsNotifier, List<CrossProbeEvent>>
crossProbeEventsProvider =
    NotifierProvider<CrossProbeEventsNotifier, List<CrossProbeEvent>>(
      CrossProbeEventsNotifier.new,
    );

/// Notifier backing [crossProbeEventsProvider].
///
/// Subscribes to the running CXP server's inbound stream so any message
/// SimCrux receives ends up in the buffer regardless of whether a
/// specific feature handler also records it. Outbound emitters (the
/// notify_selection emitters in `notify_selection_emitter.dart` and
/// the "Debug in WaveCrux" originator) call [record] explicitly when
/// they broadcast or sendTo.
class CrossProbeEventsNotifier extends Notifier<List<CrossProbeEvent>> {
  @override
  List<CrossProbeEvent> build() {
    final serverAsync = ref.watch(cxpServerProvider);
    final server = serverAsync.value;
    if (server == null) {
      return const <CrossProbeEvent>[];
    }
    final sub = server.inbound.listen((inbound) {
      record(
        CrossProbeEvent(
          timestamp: DateTime.now(),
          direction: CrossProbeDirection.inbound,
          kind: inbound.message.kind,
          peerId: inbound.from.peerId,
          summary: _summariseInbound(inbound),
        ),
      );
    });
    ref.onDispose(sub.cancel);
    return const <CrossProbeEvent>[];
  }

  /// Append a new event to the rolling buffer. Trims to
  /// [kCrossProbeEventBufferSize] (oldest dropped first).
  void record(CrossProbeEvent event) {
    final next = <CrossProbeEvent>[...state, event];
    if (next.length > kCrossProbeEventBufferSize) {
      next.removeRange(0, next.length - kCrossProbeEventBufferSize);
    }
    state = List<CrossProbeEvent>.unmodifiable(next);
  }

  /// Clear the buffer (debug / "clear log" affordance on the panel).
  void clear() {
    state = const <CrossProbeEvent>[];
  }

  String? _summariseInbound(InboundCxpMessage inbound) {
    final msg = inbound.message;
    if (msg is NotifySelection) {
      final first = msg.elements.isNotEmpty ? msg.elements.first : null;
      if (first == null) return null;
      return '${first.kind.name}: ${first.path}';
    }
    if (msg is RequestHighlight) {
      return '${msg.element.kind.name}: ${msg.element.path}';
    }
    if (msg is RequestOpenSource) {
      final loc = msg.column == null
          ? '${msg.filePath}:${msg.line}'
          : '${msg.filePath}:${msg.line}:${msg.column}';
      return loc;
    }
    return null;
  }
}
