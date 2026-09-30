// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/services/simulator/riscv_arch_driver.dart';
import 'package:simcrux/services/simulator/riscv_formal_driver.dart';

/// Which RISC-V driver produced a [TestResult] — the two row discriminators,
/// defined exactly once for the whole suite.
///
/// ## Why these live in open core
///
/// These predicates are needed by the Pro dashboards' rollups, but they
/// are not Pro knowledge. Each one is a statement about
/// **the driver's own metric contract** — which keys `riscv_arch` and
/// `riscv_formal` write — and both drivers are open core. The Pro rollups are
/// the *analysis* layer over that contract, not its owner.
///
/// The CXP stream-coordinate producer is open core and needs the same
/// question answered. Re-spelling the predicates beside the producer would
/// create a second definition of "is this a formal row", and the one
/// property pinned by test — that the two
/// discriminators **partition** a mixed run with nothing claimed twice or
/// dropped — is exactly the property a second copy silently breaks. So the
/// predicates moved down and the Pro rollups delegate; the Pro call sites and
/// their tests are unchanged.
///
/// ## Why these keys and not a `riscv.` prefix test
///
/// `riscv_formal` shares `riscv.mode` and `riscv.isa` with `riscv_arch` **by
/// reference to its constants**, so a prefix test folds bounded proofs into
/// the compatibility percentage. A `golden.*` presence test is worse: a
/// missing or empty signature fails before the comparator is ever called
/// and carries no `golden.*` keys at all, so the worst failure there
/// is — a core that produced no signature whatsoever — would vanish from its
/// own compatibility report.
abstract final class RiscvResultKind {
  /// Whether [result] came from the architectural-compatibility driver.
  ///
  /// **`riscv.signature.word_size` present AND `riscv.formal.verdict`
  /// absent.** The exclusion is load-bearing, not defensive: without it a
  /// formal row that also carried a word size would be counted twice.
  static bool isArchCompatibilityRow(TestResult result) {
    final m = result.metrics;
    if (m.containsKey(RiscvFormalDriver.kMetricVerdict)) return false;
    return m.containsKey(RiscvArchDriver.kMetricSignatureWordSize);
  }

  /// Whether [result] came from the bounded-proof driver.
  ///
  /// **`riscv.formal.verdict` present** — and only that. A proof with no
  /// `DONE (…)` line at all still carries the key (as `NO_OUTCOME`), which is
  /// the formal form of the trap above: the run that learned nothing must not
  /// disappear from the set of runs.
  static bool isFormalPropertyRow(TestResult result) =>
      result.metrics.containsKey(RiscvFormalDriver.kMetricVerdict);
}
