// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:simcrux/features/remote/services/cxp_workspace_link.dart';
import 'package:simcrux/services/remote/cxp/simcrux_cxp_identity.dart';
import 'package:simcrux/services/remote/cxp/simcrux_name_resolver.dart';

/// Who SimCrux is on CXP: its name, port, capabilities and the element kinds
/// it can show when a peer asks.
///
/// Everything else about the CXP lifecycle (the server, discovery, the peer
/// list, the four settings, acknowledgements) is the shared runtime's.
///
/// Lives under `features/remote`, not `services/remote/cxp`: it names the
/// shared UI package, which the headless CLI closure must never reach.
///
/// Held to the floor containment, not the directories the user has opened:
/// one rule screens both `request_open_source` and the hint of a
/// `request_open_artifact`, and a rooted rule would strip that hint for a
/// project SimCrux has never opened, the very request that route exists to
/// honour. The request handler applies the rooted rule to every path it
/// hands an editor.
const CruxCxpProductBinding kSimcruxCxpBinding = CruxCxpProductBinding(
  productName: simcruxCxpProductName,
  defaultPort: defaultSimcruxCxpPort,
  prefsPrefix: 'simcrux.',
  capabilities: kSimcruxCxpCapabilities,
  acceptedKinds: <ElementKind>[
    ElementKind.test,
    ElementKind.source,
    ElementKind.signal,
    ElementKind.net,
    ElementKind.port,
    ElementKind.instance,
    ElementKind.scope,
  ],
  // Named although it is the binding's default, so the decision is visible
  // where the binding is made.
  // ignore: avoid_redundant_argument_values
  containment: kCxpOpenArtifactContainment,
  nameResolver: SimCruxNameResolver(),
);
