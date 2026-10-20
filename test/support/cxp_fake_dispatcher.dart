// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:flutter_riverpod/misc.dart' show Override, ProviderListenable;

/// A cross-probe dispatcher that records every send and answers with a
/// configured outcome, so a surface's send is asserted without a socket.
///
/// Install it with `crossProbeDispatcherProvider.overrideWithValue(fake)`
/// (see [cxpFakeDispatcherOverride]).
class FakeCrossProbeDispatcher extends CrossProbeDispatcher {
  /// Creates a dispatcher whose sends end as [kind].
  FakeCrossProbeDispatcher({
    this.kind = CrossProbeOutcomeKind.sent,
    this.reason,
  }) : super(_unread);

  static T _unread<T>(ProviderListenable<T> provider) =>
      throw UnimplementedError('the fake reads nothing');

  /// How every send ends.
  final CrossProbeOutcomeKind kind;

  /// The peer's reason, for a refused send.
  final String? reason;

  /// Every send, in order.
  final List<(PeerIdentity, CrossProbeSelection?)> sent =
      <(PeerIdentity, CrossProbeSelection?)>[];

  @override
  Future<CrossProbeOutcome> send(
    PeerIdentity peer,
    CrossProbeSelection? selection, {
    String? label,
  }) async {
    sent.add((peer, selection));
    return CrossProbeOutcome(
      kind,
      target: label ?? cruxCxpDisplayName(peer.productName),
      reason: reason,
    );
  }
}

/// The override that installs [fake] as the dispatcher every surface sends
/// through.
Override cxpFakeDispatcherOverride(FakeCrossProbeDispatcher fake) =>
    crossProbeDispatcherProvider.overrideWithValue(fake);
