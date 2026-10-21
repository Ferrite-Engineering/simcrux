// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/domain/enums/test_status.dart';

/// The metric key every formal driver records its reconciled verdict
/// under: a [FormalVerdict.wireName]. The scheduler reads it so that no
/// pass/fail detector can turn a verdict that is not `PASS` into a pass.
const String kFormalVerdictMetric = 'formal.verdict';

/// The outcome a formal tool (SymbiYosys, and EQY with the same tokens)
/// reported for one task, and how SimCrux maps it onto a [TestStatus].
///
/// Lifted unchanged from the RISC-V formal track: same values, same wire
/// names, same status mapping. `RiscvFormalVerdict` is a typedef of this
/// enum, so a value written by either name is the same value.
///
/// ## The mapping is the correctness question of every formal driver
///
/// A proof that did not actually prove anything **must not read as a
/// pass**: a green row for an unproven property is a false claim. Two
/// statuses are traps and neither is reachable from here:
///
/// - [TestStatus.unknown] hands classification back to the driver's own
///   status, and `sby` can exit 0 on a run that produced no verdict at
///   all, so `unknown` is how an unproven property reads green.
/// - [TestStatus.vacuous] is **success-equivalent** to the scheduler: no
///   retry, and the work directory holding the counterexample VCD is
///   deleted. "The solver gave up" is not a vacuous pass; it is the
///   absence of a result.
///
/// So every non-`PASS` outcome maps to [TestStatus.fail], and the *shape*
/// of the failure survives losslessly in the verdict metric
/// (`riscv.formal.verdict` for the RISC-V track), which is what a
/// dashboard renders as "inconclusive" versus "counterexample found".
///
/// ## Buckets
///
/// | Token | Bucket |
/// |---|---|
/// | `PASS` | Proved |
/// | `FAIL` | Counterexample |
/// | `UNKNOWN`, `TIMEOUT` | Inconclusive |
/// | `ERROR`, `NO_OUTCOME` | Did not run |
/// | anything [fromWireName] returns null for | Unrecognised |
///
/// Unrecognised is not a value of this enum on purpose: it is the answer
/// for a verdict metric written by a newer build that this build cannot
/// parse, and it lands conservative, never in Proved. A `DONE (…)` line
/// with a token the log reader does not know is a different case: the
/// reader records that as [error] (Did not run), because the tool's own
/// verdict line is unreadable.
///
/// ## Why not [TestStatus.timeout] for [timeout]
///
/// It was considered and rejected. `TestStatus.timeout` means *SimCrux
/// killed this job*: the scheduler's own per-test timer routed through
/// `ProcessReaper.terminateTree`, and the dashboard's timeout filter is
/// read that way. An `sby` `TIMEOUT` is the opposite situation: the tool
/// ran to completion and reported, in an orderly way, that its own
/// configured solver budget expired. Conflating the two would make one
/// filter mean two things, and it would also put the driver's status at
/// odds with the `string_match` detector the importer emits (which sees
/// only "no `DONE (PASS`" and says `fail`). Driver and detector agreeing
/// in **every** case is worth more than a status nuance that is already
/// carried by a metric.
enum FormalVerdict {
  /// `DONE (PASS, rc=0)`: the property held over the whole bound.
  pass('PASS'),

  /// `DONE (FAIL, rc=2)`: a counterexample was found. This is the
  /// outcome that emits a trace VCD.
  fail('FAIL'),

  /// `DONE (UNKNOWN, rc=4)`: the engine could not decide. **Not a
  /// pass**: nothing was proven.
  unknown('UNKNOWN'),

  /// `DONE (ERROR, rc=16)`: SymbiYosys or Yosys errored out (a bad
  /// script, a missing source, an unusable engine, an SVA construct the
  /// frontend refuses). The proof never ran.
  error('ERROR'),

  /// `DONE (TIMEOUT, rc=8)`: the engine's own `timeout` option expired.
  timeout('TIMEOUT'),

  /// No `DONE (…)` line appeared in the log at all.
  ///
  /// **The sharpest trap in a formal driver.** A wrapper script, a killed
  /// pipeline or a mis-set `expect` can leave `sby` exiting 0 with no
  /// verdict. Classifying that from the exit code would report a proof
  /// that never happened as green, so it is a [TestStatus.fail] like
  /// every other non-`PASS` outcome.
  noOutcome('NO_OUTCOME');

  const FormalVerdict(this.wireName);

  /// The token the tool prints, used verbatim as the verdict metric
  /// value. Never localize or reformat it: dashboards and exported
  /// reports key off it.
  final String wireName;

  /// True only for [pass].
  bool get proved => this == FormalVerdict.pass;

  /// The SimCrux status this outcome becomes.
  ///
  /// Only [pass] is a pass. See the class doc for why `unknown` and
  /// `vacuous` are unreachable and why `timeout` is not used.
  TestStatus get status =>
      this == FormalVerdict.pass ? TestStatus.pass : TestStatus.fail;

  /// Parses a token (from a `DONE (<TOKEN>, rc=N)` line or a stored
  /// verdict metric), or null when it is not one this build recognizes.
  /// Null is the Unrecognised bucket; callers must never read it as a pass.
  static FormalVerdict? fromWireName(Object? raw) {
    if (raw is! String) return null;
    final upper = raw.trim().toUpperCase();
    for (final verdict in FormalVerdict.values) {
      if (verdict.wireName == upper) return verdict;
    }
    return null;
  }
}
