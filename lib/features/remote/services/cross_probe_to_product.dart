// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Sends [selection] to the running [productName], for a product's own
/// labelled button ("Show in NetCrux") rather than the "Cross-probe to"
/// menu: with one window it sends at once; with several it opens a menu of
/// windows at [anchor]; with none it says what to start. Every send goes
/// through the shared [sendCrossProbe], which reports the outcome.
Future<void> crossProbeToProduct(
  BuildContext context,
  WidgetRef ref, {
  required String productName,
  required CrossProbeSelection? selection,
  Offset? anchor,
}) async {
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
    await sendCrossProbe(
      context,
      ref,
      peer: target.instances.single,
      selection: selection,
      label: target.label,
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
            sendCrossProbe(
              context,
              ref,
              peer: instances[i],
              selection: selection,
              label: strings.instanceLabel(target!.label, i + 1),
            ),
          ),
        ),
    ],
  );
}
