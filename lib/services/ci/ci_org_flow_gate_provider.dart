// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/services/flow/flow_org_gate.dart';

/// The organization's implementation-flow thresholds for a desktop `--ci`
/// run, or null when none applies.
///
/// A seam, like `ciGateCeilingProvider`. Open core resolves null: it reads
/// no organization policy, so `--ci` and the headless `simcrux flow gate`
/// never exit `3`. An edition that honours the signed policy overrides it,
/// after deciding the licence tier itself. The desktop `--ci` branch of
/// `bootstrap()` reads it and hands it to `CiRunner`.
final Provider<FlowOrgGate?> ciOrgFlowGateProvider = Provider<FlowOrgGate?>(
  (ref) => null,
  name: 'ciOrgFlowGateProvider',
);
