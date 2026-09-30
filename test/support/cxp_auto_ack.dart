// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_cxp/crux_cxp.dart';

/// Makes a fake peer behave like a real receiver: reply to every
/// `request_highlight` with a `request_highlight_ack`.
///
/// Needed because SimCrux's "Debug in WaveCrux" dispatch **waits for that
/// ack** — it is the only channel on which a receiver can report what it
/// could not do (CXP §9.4, https://edacrux.app/cxp#sec-9-4), and the counterexample hand-off's whole silent
/// failure was that nothing on the sending side ever read it. A fake peer
/// that stays mute is not a stand-in for WaveCrux; it is a stand-in for a
/// wedged one, and every test that used one would now sit out the ack
/// timeout.
///
/// [honored] and [reason] shape the reply, so a test can stage the three
/// interesting receivers: a clean success (`honored: true`, no reason), a
/// partly-honoured one (`honored: true` **with** a reason — the coordinate
/// that did not resolve), and a refusal (`honored: false`).
StreamSubscription<CxpClientInbound> autoAckHighlights(
  LocalCxpClient client, {
  bool honored = true,
  String? reason,
}) => client.inbound.listen((inbound) {
  final message = inbound.message;
  if (message is! RequestHighlight) return;
  client.send(
    RequestHighlightAck(
      inReplyTo: inbound.envelope.messageId,
      honored: honored,
      reason: reason,
    ),
  );
});

/// The [CxpFakePeer]-shaped equivalent: replies on the peer's own server.
StreamSubscription<InboundCxpMessage> autoAckHighlightsFromServer(
  LocalCxpServer server, {
  bool honored = true,
  String? reason,
}) => server.inbound.listen((inbound) {
  final message = inbound.message;
  if (message is! RequestHighlight) return;
  server.sendTo(
    inbound.from.peerId,
    RequestHighlightAck(
      inReplyTo: inbound.envelope.messageId,
      honored: honored,
      reason: reason,
    ),
  );
});
