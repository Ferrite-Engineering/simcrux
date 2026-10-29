// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_flow/crux_flow.dart';
import 'package:flutter/foundation.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/flow/flow_run_reading.dart';
import 'package:simcrux/services/flow/librelane_path_check.dart';

/// The words the Flow surfaces use for a run's verdict, its steps, its
/// metrics and its path mapping. Verdict tokens and metric keys stay as
/// the tools write them in the CLI and exports; these are the localized
/// labels the GUI shows beside them.
abstract final class FlowLabels {
  /// The verdict of [reading] in words, with the step a stopped run stopped
  /// at.
  static String verdict(L10N l10n, FlowReading reading) {
    switch (reading.verdict) {
      case FlowVerdict.met:
        return l10n.flowVerdictMet;
      case FlowVerdict.violated:
        return l10n.flowVerdictViolated;
      case FlowVerdict.stopped:
        final step = reading.stoppedStep;
        return step == null
            ? l10n.flowVerdictStopped
            : l10n.flowVerdictStoppedAt(step);
      case FlowVerdict.notRun:
        return l10n.flowVerdictNotRun;
      case FlowVerdict.unrecognised:
        return l10n.flowVerdictUnrecognised;
    }
  }

  /// A step's status in words.
  static String stepStatus(L10N l10n, FlowStepStatus status) =>
      switch (status) {
        FlowStepStatus.completed => l10n.flowStepCompleted,
        FlowStepStatus.failed => l10n.flowStepFailed,
        FlowStepStatus.skipped => l10n.flowStepSkipped,
        FlowStepStatus.running => l10n.flowStepRunning,
        FlowStepStatus.notStarted => l10n.flowStepNotStarted,
      };

  /// Why LibreLane cannot run from [refusal]'s design directory, and what to
  /// do: the localized form of [LibreLaneUnsupportedPath.message].
  static String unsupportedPath(L10N l10n, LibreLaneUnsupportedPath refusal) =>
      refusal.isSpace
      ? l10n.flowLibreLanePathSpace(refusal.path)
      : l10n.flowLibreLanePathCharacter(refusal.path, refusal.characterLabel);

  /// The product name of the flow, never translated.
  static String kind(FlowKind kind) => switch (kind) {
    FlowKind.librelane => 'LibreLane',
    FlowKind.nextpnr => 'nextpnr',
  };

  /// A mapping fidelity in one word.
  static String fidelity(L10N l10n, MappingFidelity fidelity) =>
      switch (fidelity) {
        MappingFidelity.register => l10n.flowFidelityRegister,
        MappingFidelity.statement => l10n.flowFidelityStatement,
        MappingFidelity.span => l10n.flowFidelitySpan,
        MappingFidelity.unmapped => l10n.flowFidelityUnmapped,
      };

  /// Where [mapping] lands in the RTL, in words: the register, the
  /// statement, the block, or that nothing survived synthesis.
  static String mapping(L10N l10n, RtlMapping mapping) {
    final span = mapping.spans.isEmpty ? null : mapping.spans.first.format();
    switch (mapping.fidelity) {
      case MappingFidelity.register:
        return l10n.flowMappingRegister(mapping.register ?? span ?? '');
      case MappingFidelity.statement:
        return mapping.register == null
            ? l10n.flowMappingStatement(span ?? '')
            : l10n.flowMappingStatementOf(span ?? '', mapping.register!);
      case MappingFidelity.span:
        return l10n.flowMappingSpan(span ?? '');
      case MappingFidelity.unmapped:
        return l10n.flowMappingUnmapped;
    }
  }

  /// The localized label, unit and spoken unit of the metric [base], or
  /// null for a metric SimCrux has no label for (shown by its key).
  static FlowMetricLabel? metric(L10N l10n, String base) => switch (base) {
    'timing__setup__ws' => FlowMetricLabel(
      l10n.flowMetricSetupWorstSlack,
      'ns',
      l10n.flowUnitNanoseconds,
    ),
    'timing__hold__ws' => FlowMetricLabel(
      l10n.flowMetricHoldWorstSlack,
      'ns',
      l10n.flowUnitNanoseconds,
    ),
    'timing__setup__wns' => FlowMetricLabel(
      l10n.flowMetricSetupWns,
      'ns',
      l10n.flowUnitNanoseconds,
    ),
    'timing__hold__wns' => FlowMetricLabel(
      l10n.flowMetricHoldWns,
      'ns',
      l10n.flowUnitNanoseconds,
    ),
    'timing__setup__tns' => FlowMetricLabel(
      l10n.flowMetricSetupTns,
      'ns',
      l10n.flowUnitNanoseconds,
    ),
    'timing__hold__tns' => FlowMetricLabel(
      l10n.flowMetricHoldTns,
      'ns',
      l10n.flowUnitNanoseconds,
    ),
    'timing__setup_vio__count' => FlowMetricLabel(
      l10n.flowMetricSetupViolations,
    ),
    'timing__hold_vio__count' => FlowMetricLabel(
      l10n.flowMetricHoldViolations,
    ),
    'fmax__achieved__mhz' => FlowMetricLabel(
      l10n.flowMetricAchievedClock,
      'MHz',
      l10n.flowUnitMegahertz,
    ),
    'design__instance__area' => FlowMetricLabel(
      l10n.flowMetricCellArea,
      'µm²',
      l10n.flowUnitSquareMicrometres,
    ),
    'design__instance__utilization' => FlowMetricLabel(
      l10n.flowMetricUtilization,
    ),
    'design__instance__count' => FlowMetricLabel(l10n.flowMetricCellCount),
    'route__drc_errors' => FlowMetricLabel(l10n.flowMetricRouteDrc),
    'magic__drc_error__count' => FlowMetricLabel(l10n.flowMetricMagicDrc),
    'design__lvs_error__count' => FlowMetricLabel(l10n.flowMetricLvs),
    'route__antenna_violation__count' => FlowMetricLabel(
      l10n.flowMetricAntenna,
    ),
    'antenna__violating__nets' => FlowMetricLabel(l10n.flowMetricAntennaNets),
    'design__xor_difference__count' => FlowMetricLabel(l10n.flowMetricXor),
    'power__total' => FlowMetricLabel(
      l10n.flowMetricPower,
      'W',
      l10n.flowUnitWatts,
    ),
    'utilization__used__bel' => FlowMetricLabel(l10n.flowMetricBelsUsed),
    'utilization__available__bel' => FlowMetricLabel(
      l10n.flowMetricBelsAvailable,
    ),
    _ => null,
  };

  /// A metric value as shown: integers whole, others to four significant
  /// places, text as written.
  static String value(Object? value) {
    if (value == null) return '';
    if (value is int) return '$value';
    if (value is double) {
      if (value == value.roundToDouble() && value.abs() < 1e12) {
        return value.toStringAsFixed(0);
      }
      final abs = value.abs();
      if (abs >= 1000 || abs < 0.001) return value.toStringAsExponential(3);
      return double.parse(value.toStringAsPrecision(4)).toString();
    }
    return '$value';
  }

  /// A delay in nanoseconds, to three decimals.
  static String nanoseconds(double ns) => ns.toStringAsFixed(3);
}

/// A metric's localized label and its unit, shown and spoken.
@immutable
class FlowMetricLabel {
  /// Creates the label.
  const FlowMetricLabel(this.label, [this.unit, this.spokenUnit]);

  /// The localized name.
  final String label;

  /// The unit as shown (`ns`), when the metric has one.
  final String? unit;

  /// The unit as spoken ("nanoseconds").
  final String? spokenUnit;
}
