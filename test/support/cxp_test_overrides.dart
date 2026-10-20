// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:simcrux/features/remote/simcrux_cxp_binding.dart';

/// The root overrides a test needs to mount a surface that reads the shared
/// CXP providers (the settings section, the cross-probe panel, a row menu,
/// the toolbar badge): SimCrux's binding, the transport off so nothing binds
/// a socket, and launch settings so nothing reads preferences.
///
/// [running] and [port] make the server read as up (what the status line
/// shows) without starting one. [peers] is the connected peer list.
/// [handler] replaces the request handler when a test drives one.
List<Override> simcruxCxpTestOverrides({
  bool enabled = true,
  bool running = false,
  int port = 54325,
  List<PeerIdentity>? peers,
  CruxCxpRequestHandler? handler,
}) => <Override>[
  cruxCxpProductBindingProvider.overrideWithValue(kSimcruxCxpBinding),
  cruxCxpTransportAvailableProvider.overrideWithValue(false),
  cruxCxpLaunchSettingsProvider.overrideWithValue(
    CruxCxpSettings(enabled: enabled, port: port),
  ),
  if (running)
    cruxCxpServerStatusProvider.overrideWithValue((
      running: true,
      port: port,
      problem: null,
    )),
  if (peers != null) cruxCxpPeersProvider.overrideWithValue(peers),
  if (handler != null) cruxCxpRequestHandlerProvider.overrideWithValue(handler),
];

/// A peer identity for a suite product, for peer-list overrides.
PeerIdentity cxpTestPeer(String productName, {String? id}) => PeerIdentity(
  peerId: id ?? '$productName-1',
  productName: productName,
  productVersion: '1.0.0',
);
