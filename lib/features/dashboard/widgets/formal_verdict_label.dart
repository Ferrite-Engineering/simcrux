// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/formal_diagnostic.dart';
import 'package:simcrux/domain/models/formal_result_summary.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// The localized words for a formal row's verdict: what the Verdict column
/// shows, what the status glyph's tooltip says and what a screen reader
/// hears for the row.
///
/// A bounded pass is "Proved over N steps", never a bare "Proved"; a pass
/// whose bound was not recorded says it was bounded; a pass that checked no
/// property says so instead of claiming a proof. An EQY row is "Proved
/// equivalent" only when every partition was, and otherwise says how many
/// of its partitions were not. The verdict tokens (`PASS`, `FAIL`) are wire
/// names and never appear here.
String formalVerdictLabel(L10N l10n, FormalResultSummary summary) {
  if (summary.wording == FormalVerdictWording.didNotRun) {
    switch (summary.notRunReason) {
      case FormalNotRunReason.svaUnsupported:
        return l10n.formalVerdictDidNotRunSva;
      case FormalNotRunReason.dropped:
        return l10n.formalVerdictDidNotRunDropped;
      case null:
        break;
    }
  }
  final eqy = summary.tool == FormalResultSummary.kToolEqy;
  return switch (summary.wording) {
    FormalVerdictWording.proved => l10n.formalVerdictProved,
    FormalVerdictWording.provedEquivalent => l10n.formalVerdictProvedEquivalent(
      summary.properties ?? 0,
    ),
    FormalVerdictWording.provedOverSteps => l10n.formalVerdictProvedOverSteps(
      summary.depthConfigured ?? 0,
    ),
    FormalVerdictWording.provedBounded => l10n.formalVerdictProvedBounded,
    FormalVerdictWording.reached => l10n.formalVerdictReached,
    FormalVerdictWording.noPropertiesChecked =>
      eqy
          ? l10n.formalVerdictNoPartitionsChecked
          : l10n.formalVerdictNoPropertiesChecked,
    // An EQY run that is not Proved names how many of its partitions were
    // not proved: EQY's FAIL covers an undecided partition as well as a
    // counterexample, so the bucket word alone would overstate it.
    FormalVerdictWording.counterexample =>
      eqy && summary.properties != null
          ? l10n.formalVerdictNotProvedEquivalent(
              (summary.propertiesFailed ?? 0) +
                  (summary.propertiesUndecided ?? 0),
              summary.properties!,
            )
          : l10n.formalVerdictCounterexample,
    FormalVerdictWording.notReached => l10n.formalVerdictNotReached,
    FormalVerdictWording.inconclusive => l10n.formalVerdictInconclusive,
    FormalVerdictWording.didNotRun => l10n.formalVerdictDidNotRun,
    FormalVerdictWording.unrecognised => l10n.formalVerdictUnrecognized,
  };
}

/// What a screen reader hears for a formal row's verdict: the verdict, and
/// the pre-trace marker after it when the result depends on state from
/// before the trace began. The marker is part of the fact, so it is never
/// only drawn.
String formalVerdictSpoken(L10N l10n, FormalResultSummary summary) {
  final verdict = formalVerdictLabel(l10n, summary);
  return summary.pretrace == null
      ? verdict
      : l10n.formalVerdictWithPretrace(verdict);
}

/// The localized phrase for a construct class ("a temporal implication").
String formalSvaClassPhrase(L10N l10n, SvaConstructClass c) => switch (c) {
  SvaConstructClass.implication => l10n.formalSvaClassImplication,
  SvaConstructClass.delay => l10n.formalSvaClassDelay,
  SvaConstructClass.repetition => l10n.formalSvaClassRepetition,
  SvaConstructClass.sequenceOp => l10n.formalSvaClassSequenceOp,
  SvaConstructClass.namedSequence => l10n.formalSvaClassNamedSequence,
  SvaConstructClass.defaultClocking => l10n.formalSvaClassDefaultClocking,
  SvaConstructClass.livenessOp => l10n.formalSvaClassLivenessOp,
  SvaConstructClass.other => l10n.formalSvaClassOther,
};

/// The glyph for a formal verdict, distinct per bucket so the shape says it
/// as well as the colour.
IconData formalVerdictIcon(FormalVerdictWording wording) => switch (wording) {
  FormalVerdictWording.proved ||
  FormalVerdictWording.provedEquivalent ||
  FormalVerdictWording.provedOverSteps ||
  FormalVerdictWording.provedBounded ||
  FormalVerdictWording.reached => Icons.check_circle,
  FormalVerdictWording.noPropertiesChecked => Icons.check_circle_outline,
  FormalVerdictWording.counterexample ||
  FormalVerdictWording.notReached => Icons.cancel,
  FormalVerdictWording.inconclusive => Icons.help_outline,
  FormalVerdictWording.didNotRun => Icons.report_problem_outlined,
  FormalVerdictWording.unrecognised => Icons.help_center_outlined,
};

/// The formal summary a results row's status glyph and speech use in place
/// of its [TestStatus], or null when the status itself should be shown.
///
/// Only a finished pass or fail is replaced: a timeout, a cancel, a skip or
/// a running row is SimCrux's own fact about the job, not the engine's, and
/// keeps its status.
FormalResultSummary? formalSummaryForStatus(
  TestStatus status,
  Map<String, String> metrics,
) {
  if (status != TestStatus.pass && status != TestStatus.fail) return null;
  return FormalResultSummary.fromMetrics(metrics);
}
