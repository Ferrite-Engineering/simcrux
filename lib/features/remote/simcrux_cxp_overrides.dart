// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:crux_window_chrome/crux_window_chrome.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:simcrux/features/remote/providers/inbound_request_handler.dart';
import 'package:simcrux/features/remote/simcrux_cxp_binding.dart';
import 'package:simcrux/services/remote/cxp/simcrux_cxp_identity.dart';

/// The root-scope overrides that make the shared CXP lifecycle SimCrux's:
/// who it is, what it does when a peer asks, which version it announces, how
/// it asks for attention, and where an outbound cross-probe is counted.
///
/// [launch] is the CXP settings loaded before `runApp` (desktop only; null
/// makes the settings load in the background, with the server off until they
/// have). Spread into `bootstrap()`'s root overrides, in the same container as
/// the Pro overlay's `extraOverrides`. Riverpod refuses to build a container
/// that overrides one provider twice, so `extraOverrides` must not override
/// any provider listed here: a caller that needs other launch settings passes
/// them as `bootstrap(cxpLaunchSettings: ...)`.
///
/// `crossProbeGateProvider` is deliberately not overridden: cross-probing is
/// free on every tier, sending as well as receiving.
List<Override> simcruxCxpOverrides({CruxCxpSettings? launch}) => <Override>[
  cruxCxpProductBindingProvider.overrideWithValue(kSimcruxCxpBinding),
  if (launch != null) cruxCxpLaunchSettingsProvider.overrideWithValue(launch),
  cruxCxpRequestHandlerProvider.overrideWith(SimcruxCxpRequestHandler.new),
  cruxCxpProductVersionProvider.overrideWith(
    (ref) async => kSimcruxCxpAdvertisedVersion,
  ),
  // The runtime calls it only when a request was honoured and the
  // "Request attention" setting is on.
  cruxCxpAttentionRequesterProvider.overrideWithValue(requestUserAttention),
  // The one place an outbound `cxp.crossprobe` is counted, for every surface
  // that sends through the shared dispatcher. A send that never left
  // (denied, nothing selected, server off, no peers) is not a cross-probe.
  crossProbeSendObserverProvider.overrideWith(
    (ref) => (record) {
      final kind = record.outcome.kind;
      if (kind == CrossProbeOutcomeKind.denied ||
          kind == CrossProbeOutcomeKind.nothingSelected ||
          kind == CrossProbeOutcomeKind.serverOff ||
          kind == CrossProbeOutcomeKind.noPeers) {
        return;
      }
      ref
          .read(telemetryServiceProvider)
          .record(
            TelemetryEvent(
              'cxp.crossprobe',
              properties: <String, Object?>{
                'direction': 'outbound',
                'honored': kind == CrossProbeOutcomeKind.sent,
              },
            ),
          );
    },
  ),
];
