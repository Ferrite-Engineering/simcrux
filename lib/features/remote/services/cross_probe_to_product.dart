// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/remote/services/cross_probe_attempts.dart';

/// Sends [selection] to the running [productName], for a product's own
/// labelled button ("Show in NetCrux") rather than the "Cross-probe to"
/// menu: with one window it sends at once; with several it opens a menu of
/// windows at [anchor]; with none it says what to start. Every send reports
/// its outcome.
///
/// [attempts] are tried in order until the product shows one (see
/// [sendCrossProbeAttempts]); [allDeclinedReason] is what the user is told
/// when it declined every one. A single [selection] is the plain send through
/// the shared [sendCrossProbe].
Future<void> crossProbeToProduct(
  BuildContext context,
  WidgetRef ref, {
  required String productName,
  CrossProbeSelection? selection,
  List<CrossProbeSelection>? attempts,
  String? allDeclinedReason,
  Offset? anchor,
}) async {
  assert(
    selection == null || attempts == null,
    'name either one selection or the attempts, not both',
  );
  final toSend = attempts ?? <CrossProbeSelection>[?selection];
  final strings = cruxCxpStringsOf(context, ref.read);
  CrossProbeTarget? target;
  for (final t in ref.read(crossProbeTargetsProvider)) {
    if (t.productName == productName) target = t;
  }
  if (target == null) {
    reportCrossProbeOutcome(
      context,
      const CrossProbeOutcome(CrossProbeOutcomeKind.noPeers),
      strings,
    );
    return;
  }
  if (!target.hasSeveralInstances) {
    await sendCrossProbeAttempts(
      context,
      ref,
      peer: target.instances.single,
      attempts: toSend,
      label: target.label,
      allDeclinedReason: allDeclinedReason,
    );
    return;
  }
  final box = context.findRenderObject() as RenderBox?;
  final position =
      anchor ??
      (box == null
          ? Offset.zero
          : box.localToGlobal(box.size.bottomLeft(Offset.zero)));
  final instances = target.instances;
  await showCruxContextMenu(
    context,
    globalPosition: position,
    entries: <CruxMenuEntry>[
      for (var i = 0; i < instances.length; i++)
        CruxMenuItem(
          key: ValueKey('crossProbeToProduct:${instances[i].peerId}'),
          label: strings.instanceLabel(target.label, i + 1),
          onSelected: () => unawaited(
            sendCrossProbeAttempts(
              context,
              ref,
              peer: instances[i],
              attempts: toSend,
              label: strings.instanceLabel(target!.label, i + 1),
              allDeclinedReason: allDeclinedReason,
            ),
          ),
        ),
    ],
  );
}
