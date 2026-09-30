// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/domain/enums/test_status.dart';

/// The outcome SymbiYosys itself reported for one bounded proof, and how
/// SimCrux maps it onto a [TestStatus].
///
/// ## The mapping is the correctness question of the whole driver
///
/// A proof that did not actually prove anything **must not read as a
/// pass**: a green row for an unproven property is a false compatibility
/// claim. Two statuses are traps and neither is reachable from here:
///
/// - [TestStatus.unknown] hands classification back to the driver's own
///   status, and `sby` can exit 0 on a run that produced no verdict at
///   all — so `unknown` is how an unproven property reads green.
/// - [TestStatus.vacuous] is **success-equivalent** to the scheduler: no
///   retry, and the work directory holding the counterexample VCD is
///   deleted. "The solver gave up" is not a vacuous pass; it is the
///   absence of a result.
///
/// So every non-`PASS` outcome maps to [TestStatus.fail], and the *shape*
/// of the failure survives losslessly in the `riscv.formal.verdict`
/// metric, which is what the Pro formal dashboard renders as
/// "inconclusive" versus "counterexample found".
///
/// ## Why not [TestStatus.timeout] for [timeout]
///
/// It was considered and rejected. `TestStatus.timeout` means *SimCrux
/// killed this job* — the scheduler's own per-test timer routed through
/// `ProcessReaper.terminateTree` — and the dashboard's timeout filter is
/// read that way. An `sby` `TIMEOUT` is the opposite situation: the tool
/// ran to completion and reported, in an orderly way, that its own
/// configured solver budget expired. Conflating the two would make one
/// filter mean two things, and it would also put the driver's status at
/// odds with the `string_match` detector the importer emits (which sees
/// only "no `DONE (PASS`" and says `fail`). Driver and detector agreeing
/// in **every** case is worth more than a status nuance that is already
/// carried by a metric.
enum RiscvFormalVerdict {
  /// `DONE (PASS, rc=0)` — the property held over the whole bound.
  pass('PASS'),

  /// `DONE (FAIL, rc=2)` — a counterexample was found. This is the
  /// outcome that emits a trace VCD.
  fail('FAIL'),

  /// `DONE (UNKNOWN, rc=4)` — the engine could not decide. **Not a
  /// pass**: nothing was proven.
  unknown('UNKNOWN'),

  /// `DONE (ERROR, rc=16)` — SymbiYosys or Yosys errored out (a bad
  /// script, a missing source, an unusable engine). The proof never ran.
  error('ERROR'),

  /// `DONE (TIMEOUT, rc=8)` — the engine's own `timeout` option expired.
  timeout('TIMEOUT'),

  /// No `DONE (…)` line appeared in the log at all.
  ///
  /// **The sharpest trap in this driver.** A wrapper script, a killed
  /// pipeline or a mis-set `expect` can leave `sby` exiting 0 with no
  /// verdict. Classifying that from the exit code would report a proof
  /// that never happened as green, so it is a [TestStatus.fail] like
  /// every other non-`PASS` outcome.
  noOutcome('NO_OUTCOME');

  const RiscvFormalVerdict(this.wireName);

  /// The token `sby` prints, used verbatim as the `riscv.formal.verdict`
  /// metric value. Never localize or reformat it — the Pro dashboard and
  /// the exported report key off it.
  final String wireName;

  /// True only for [pass].
  bool get proved => this == RiscvFormalVerdict.pass;

  /// The SimCrux status this outcome becomes.
  ///
  /// Only [pass] is a pass. See the class doc for why `unknown` and
  /// `vacuous` are unreachable and why `timeout` is not used.
  TestStatus get status =>
      this == RiscvFormalVerdict.pass ? TestStatus.pass : TestStatus.fail;

  /// Parses the token from a `DONE (<TOKEN>, rc=N)` line, or null when it
  /// is not one we recognize.
  static RiscvFormalVerdict? fromWireName(Object? raw) {
    if (raw is! String) return null;
    final upper = raw.trim().toUpperCase();
    for (final verdict in RiscvFormalVerdict.values) {
      if (verdict.wireName == upper) return verdict;
    }
    return null;
  }
}
