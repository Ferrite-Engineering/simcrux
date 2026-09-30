// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_policy/crux_policy.dart';

/// SimCrux's namespace in `.crux-policy.json`, and its audit event kinds.
///
/// **These declare the keys; they do not implement the features the keys
/// configure.** Theme packs, workspace templates, symbol libraries, the
/// retention policy and the CI gate threshold are separate follow-ups that
/// become small once this exists. What this file buys is that a key an
/// administrator writes is a key the application honours, with the shared
/// precedence and the shared diagnostics.
///
/// The normative schema is the suite policy reference
/// (https://edacrux.app/policy-reference). Register against **its** names: it
/// unified several keys the four products had each named differently, so a
/// product's own wording is not authoritative here.
abstract final class SimCruxPolicyKeys {
  /// The product id this namespace lives under.
  static const String productId = 'simcrux';

  /// `products.simcrux.defaultSimulator` — the simulator a new project starts on.
  static const String defaultSimulator = 'defaultSimulator';

  /// `products.simcrux.simulatorBinaryPolicy` — which simulator binaries may be invoked.
  static const String simulatorBinaryPolicy = 'simulatorBinaryPolicy';

  /// `products.simcrux.ciGateThreshold` — the failure count a CI run may not exceed.
  static const String ciGateThreshold = 'ciGateThreshold';

  /// `products.simcrux.retentionPolicy` — how long results are kept, by status.
  static const String retentionPolicy = 'retentionPolicy';

  /// `products.simcrux.distributedExecutionBackend` — the templated job-submission backend.
  static const String distributedExecutionBackend =
      'distributedExecutionBackend';

  /// `products.simcrux.teamDatabaseSubmitter` — the name pooled runs are
  /// attributed to in the shared team results database.
  ///
  /// Registered here rather than in the Pro overlay because the namespace is
  /// per product, not per tier: an administrator writes one file for SimCrux,
  /// and which of its keys happen to configure a licensed feature is not
  /// something they should have to know. `distributedExecutionBackend` above
  /// is registered on the same basis.
  static const String teamDatabaseSubmitter = 'teamDatabaseSubmitter';

  /// Every key this product registers, for the conformance test.
  static const Set<String> all = <String>{
    defaultSimulator,
    simulatorBinaryPolicy,
    ciGateThreshold,
    retentionPolicy,
    distributedExecutionBackend,
    teamDatabaseSubmitter,
  };
}

/// The audit events SimCrux records.
///
/// **Kinds are per-product on purpose.** The envelope is shared; a shared enum
/// of kinds would need editing in `crux-shared` every time any one of four
/// products learned a new event.
abstract final class SimCruxAuditKinds {
  /// `regression.started`
  static const String regressionStarted = 'regression.started';

  /// `regression.finished`
  static const String regressionFinished = 'regression.finished';

  /// `simulator.invoked`
  static const String simulatorInvoked = 'simulator.invoked';

  /// `distributed.job.submitted`
  static const String distributedJobSubmitted = 'distributed.job.submitted';

  /// `retention.purged`
  static const String retentionPurged = 'retention.purged';

  /// `results.pushed` — a run's results were written to the shared team
  /// database.
  ///
  /// Registered rather than folded into [distributedJobSubmitted], which is
  /// about dispatching work to a scheduler. This one records that verification
  /// data left the machine that produced it and entered a store the whole team
  /// reads, which is a different fact and the one an auditor asks about.
  static const String resultsPushed = 'results.pushed';

  /// Every kind this product registers, for the conformance test.
  static const Set<String> all = <String>{
    regressionStarted,
    regressionFinished,
    simulatorInvoked,
    distributedJobSubmitted,
    retentionPurged,
    resultsPushed,
  };
}

/// A resolver scoped to this product's namespace.
///
/// A key naming a *different* product is ignored silently — one file serves a
/// mixed fleet, so a SimCrux install meeting another product's keys is the
/// normal case rather than a misconfiguration.
PolicyResolver simcruxPolicyResolver(PolicyDocument document) =>
    PolicyResolver(document: document, productId: SimCruxPolicyKeys.productId);
