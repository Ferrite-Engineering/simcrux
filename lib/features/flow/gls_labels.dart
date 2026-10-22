// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/flow/gate_level/gls_outcome.dart';
import 'package:simcrux/services/flow/gate_level/gls_result.dart';

/// The localized words for a gate-level result: what the Verdict column
/// shows, what the status glyph says, and what a screen reader hears.
///
/// Outcome tokens (`equal`, `x_only`, `differs`, `not_run`) are wire names and
/// never appear here. "X-asymmetry only" is a neutral note, and "Differs" on a
/// completed run is a finding, never error red.
abstract final class GlsLabels {
  /// The outcome's name.
  static String outcome(L10N l10n, GlsOutcome outcome) => switch (outcome) {
    GlsOutcome.equal => l10n.glsOutcomeEqual,
    GlsOutcome.xOnly => l10n.glsOutcomeXOnly,
    GlsOutcome.differs => l10n.glsOutcomeDiffers,
    GlsOutcome.notRun => l10n.glsOutcomeNotRun,
  };

  /// The sentence for why a test did not run.
  static String reason(L10N l10n, GlsNotRunReason reason) => switch (reason) {
    GlsNotRunReason.failsAtRtl => l10n.glsReasonFailsAtRtl,
    GlsNotRunReason.rtlBuildFailed => l10n.glsReasonRtlBuildFailed,
    GlsNotRunReason.rtlLanguage => l10n.glsReasonRtlLanguage,
    GlsNotRunReason.simulatorUnsupported => l10n.glsReasonSimulatorUnsupported,
    GlsNotRunReason.portShape => l10n.glsReasonPortShape,
    GlsNotRunReason.gateBuildFailed => l10n.glsReasonGateBuildFailed,
    GlsNotRunReason.modelsMissing => l10n.glsReasonModelsMissing,
    GlsNotRunReason.netlistMissing => l10n.glsReasonNetlistMissing,
    GlsNotRunReason.runUnreadable => l10n.glsReasonRunUnreadable,
    GlsNotRunReason.noDesignSources => l10n.glsReasonNoDesignSources,
    GlsNotRunReason.dutScope => l10n.glsReasonDutScope,
    GlsNotRunReason.clockUnknown => l10n.glsReasonClockUnknown,
    GlsNotRunReason.clockAmbiguous => l10n.glsReasonClockAmbiguous,
    GlsNotRunReason.vcdUnreadable => l10n.glsReasonVcdUnreadable,
    GlsNotRunReason.vcdTooLarge => l10n.glsReasonVcdTooLarge,
    GlsNotRunReason.noSamples => l10n.glsReasonNoSamples,
    GlsNotRunReason.toolMissing => l10n.glsReasonToolMissing,
    GlsNotRunReason.cancelled => l10n.glsReasonCancelled,
  };

  /// Both counts, always: "2 real differences, 12 X-asymmetries".
  static String counts(L10N l10n, GlsResultView view) => l10n.glsCountsJoined(
    l10n.glsRealDifferences(view.realDiffs ?? 0),
    l10n.glsXAsymmetries(view.xDiffs ?? 0),
  );

  /// The Verdict cell: the outcome and both counts for a test that ran, the
  /// outcome alone for one that did not.
  static String verdict(L10N l10n, GlsResultView view) =>
      view.outcome == GlsOutcome.notRun
      ? outcome(l10n, view.outcome)
      : l10n.glsVerdictWithCounts(
          outcome(l10n, view.outcome),
          counts(l10n, view),
        );

  /// What a screen reader hears for the row: the test, that it is gate level,
  /// the outcome and both counts (or the reason it did not run).
  static String spoken(L10N l10n, GlsResultView view, String test) {
    if (view.outcome == GlsOutcome.notRun) {
      return l10n.glsRowSpokenNotRun(
        test,
        view.reason == null ? '' : reason(l10n, view.reason!),
      );
    }
    return l10n.glsRowSpoken(
      test,
      outcome(l10n, view.outcome),
      counts(l10n, view),
    );
  }

  /// The glyph, distinct per outcome so the shape says it as well as the
  /// words: a check for equal, an information mark for X-asymmetry only, a
  /// flag for a difference, and a dash for a test that did not run.
  static IconData icon(GlsOutcome outcome) => switch (outcome) {
    GlsOutcome.equal => Icons.check_circle,
    GlsOutcome.xOnly => Icons.info_outline,
    GlsOutcome.differs => Icons.flag_outlined,
    GlsOutcome.notRun => Icons.remove_circle_outline,
  };

  /// The glyph's hue. A difference on a completed run is a finding: the
  /// tertiary colour, never the error colour. X-asymmetry only is neutral.
  static Color color(GlsOutcome outcome, ColorScheme scheme) =>
      switch (outcome) {
        GlsOutcome.equal => scheme.primary,
        GlsOutcome.xOnly => scheme.onSurfaceVariant,
        GlsOutcome.differs => scheme.tertiary,
        GlsOutcome.notRun => scheme.onSurfaceVariant,
      };

  /// The sentence spoken when a gate-level run ends, or null when [results]
  /// hold no gate-level result.
  static String? completion(L10N l10n, Iterable<TestResult> results) {
    final views = <GlsResultView>[
      for (final r in results) ?GlsResultView.of(r),
    ];
    if (views.isEmpty) return null;
    int count(GlsOutcome o) => views.where((v) => v.outcome == o).length;
    return l10n.glsCompleted(
      count(GlsOutcome.equal),
      count(GlsOutcome.xOnly),
      count(GlsOutcome.differs),
      count(GlsOutcome.notRun),
    );
  }
}
