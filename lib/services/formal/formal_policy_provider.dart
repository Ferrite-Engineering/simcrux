// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/services/formal/formal_org_policy.dart';

/// The organization's formal policy, applied to every `sby` result the
/// app and the desktop `--ci` branch run, or null when none applies.
///
/// A seam, like `ciGateCeilingProvider`. Open core resolves null: it reads no
/// organization policy, and a formal verdict is correctness and is never
/// gated. An edition that honours the organization's signed policy overrides
/// it, after deciding the licence tier itself; the policy never decides a
/// tier. `simulatorDriverRegistryProvider` wraps the `sby` driver in
/// [FormalPolicyEnforcingDriver] when this is set.
final Provider<FormalPolicyEnforcement?> formalPolicyEnforcementProvider =
    Provider<FormalPolicyEnforcement?>(
      (ref) => null,
      name: 'formalPolicyEnforcementProvider',
    );
