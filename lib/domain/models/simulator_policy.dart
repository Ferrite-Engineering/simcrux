// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

/// What an organization has said about simulators, as the project loader
/// applies it.
///
/// Open core never builds one of these from a policy file: it holds
/// [SimulatorPolicy.none], and an edition that reads organization policy
/// supplies a resolved value through `simulatorPolicyProvider`. The loader
/// only has to know the two answers, not where they came from.
///
/// **This is not binary pinning.** [allowedSimulatorIds] constrains which
/// simulator *ids* a project's tests may name. It does not decide which
/// executable runs for an allowed id: that is still the user's
/// Settings > Simulators path, or the project file's own `simulators:` block
/// when project-defined tooling is allowed.
@immutable
final class SimulatorPolicy {
  /// Creates a [SimulatorPolicy].
  const SimulatorPolicy({this.fallbackSimulatorId, this.allowedSimulatorIds});

  /// No organization policy: every simulator id is allowed and a test that
  /// names none is a load error.
  static const SimulatorPolicy none = SimulatorPolicy();

  /// The simulator a test runs on when the project file names none at any
  /// level: not in `defaults.simulator` (its own or an including file's), not
  /// on the suite, not on the test.
  ///
  /// The project file always wins. This is the last level, never an
  /// override.
  final String? fallbackSimulatorId;

  /// The simulator ids a project's tests may use, or null for no
  /// restriction.
  ///
  /// When set, a test whose resolved simulator is not in the set is a load
  /// error that names the test, its simulator and the allowed ids. An empty
  /// set allows nothing, which is what it says.
  final Set<String>? allowedSimulatorIds;

  /// Whether [simulatorId] may run under this policy.
  bool allows(String simulatorId) =>
      allowedSimulatorIds?.contains(simulatorId) ?? true;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! SimulatorPolicy) return false;
    if (other.fallbackSimulatorId != fallbackSimulatorId) return false;
    final mine = allowedSimulatorIds;
    final theirs = other.allowedSimulatorIds;
    if (mine == null || theirs == null) return mine == theirs;
    return mine.length == theirs.length && mine.containsAll(theirs);
  }

  @override
  int get hashCode {
    final allowed = allowedSimulatorIds;
    return Object.hash(
      fallbackSimulatorId,
      allowed == null ? null : Object.hashAllUnordered(allowed),
    );
  }

  @override
  String toString() =>
      'SimulatorPolicy(fallback: $fallbackSimulatorId, '
      'allowed: $allowedSimulatorIds)';
}
