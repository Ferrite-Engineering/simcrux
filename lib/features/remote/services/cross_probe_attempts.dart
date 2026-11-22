// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Sends [attempts] to [peer] one after another, stopping at the first the
/// peer shows, and reports the outcome once.
///
/// For a selection the sender cannot check against the peer's design: a
/// directed cross-probe carries one element, so naming several candidates
/// leaves the peer no way to choose one it has. An attempt the peer declines
/// (it does not have the element) moves on to the next; any other end (shown,
/// no answer, peer gone, server off) is final.
///
/// When every attempt was declined, [allDeclinedReason] (a sentence for the
/// user, already localised) replaces the last decline's reason, because the
/// last one only describes the last attempt. Null keeps the peer's own.
///
/// One attempt is the ordinary [sendCrossProbe].
Future<CrossProbeOutcome> sendCrossProbeAttempts(
  BuildContext context,
  WidgetRef ref, {
  required PeerIdentity peer,
  required List<CrossProbeSelection> attempts,
  String? label,
  String? allDeclinedReason,
}) async {
  if (attempts.length <= 1) {
    return await sendCrossProbe(
      context,
      ref,
      peer: peer,
      selection: attempts.isEmpty ? null : attempts.single,
      label: label,
    );
  }
  // Read before any await: the surface that started the send may close.
  final strings = cruxCxpStringsOf(context, ref.read);
  final dispatcher = ref.read(crossProbeDispatcherProvider);
  final gate = ref.read(crossProbeGateProvider);
  final who = label ?? cruxCxpDisplayName(peer.productName);
  if (gate != null && !await gate.admit(context, peer)) {
    return CrossProbeOutcome(CrossProbeOutcomeKind.denied, target: who);
  }
  var outcome = const CrossProbeOutcome(CrossProbeOutcomeKind.nothingSelected);
  for (final attempt in attempts) {
    outcome = await dispatcher.send(peer, attempt, label: who);
    if (outcome.kind != CrossProbeOutcomeKind.refused) break;
  }
  if (outcome.kind == CrossProbeOutcomeKind.refused &&
      allDeclinedReason != null) {
    outcome = CrossProbeOutcome(
      CrossProbeOutcomeKind.refused,
      target: outcome.target,
      reason: allDeclinedReason,
    );
  }
  if (context.mounted) reportCrossProbeOutcome(context, outcome, strings);
  return outcome;
}
