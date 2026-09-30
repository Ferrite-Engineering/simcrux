// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:simcrux/domain/enums/riscv_host_platform.dart';
import 'package:simcrux/domain/enums/riscv_toolchain_component.dart';
import 'package:simcrux/domain/models/riscv_toolchain_report.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Renders a [RiscvToolchainReport] with **actionable, per-platform**
/// guidance for whatever is missing.
///
/// ## Why the guidance is authored here and not read off the report
///
/// `RiscvComponentReport.remediation` is an unlocalized English literal, on
/// the same channel as `SimulatorNotAvailableException.remediation` — that
/// is what reaches logs, `failureMessage` and the plain-text App
/// Diagnostics body, none of which has a localization path. Localization
/// covers **widget-rendered strings only**: config-loader diagnostics and
/// that exception are unlocalized English, and inventing a localization
/// channel for them is a far larger change than the RISC-V path warrants.
///
/// So the widget authors its own copy from the start, keyed on
/// [RiscvToolchainComponent] × [RiscvHostPlatform], rather than plumbing a
/// string out of a value object. The two say the same thing; only this one
/// is translated.
///
/// ## Never gated
///
/// Toolchain guidance is part of answering *"is my core correct?"*, which is
/// free forever. There is no tier check here and there must never be one.
class RiscvToolchainReportView extends StatelessWidget {
  /// Creates a [RiscvToolchainReportView].
  const RiscvToolchainReportView({
    required this.report,
    required this.platform,
    super.key,
  });

  /// The probe result to render.
  final RiscvToolchainReport report;

  /// The host platform the guidance is phrased for. Injected so the locale
  /// sweep can render all three from one runner.
  final RiscvHostPlatform platform;

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    final theme = Theme.of(context);
    if (report.components.isEmpty) {
      // Demo mode probes nothing, deliberately — there is no component
      // whose absence would be a defect.
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          l10n.riscvToolchainDemoModeNote,
          style: theme.textTheme.bodyMedium,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.riscvToolchainTitle,
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        Text(
          report.complete
              ? l10n.riscvToolchainAllPresent
              : l10n.riscvToolchainMissingSummary(
                  report.missing
                      .map((c) => componentLabel(l10n, c.component))
                      .join(', '),
                ),
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        for (final entry in report.components)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _ComponentTile(
              entry: entry,
              label: componentLabel(l10n, entry.component),
              status: entry.found
                  ? l10n.riscvToolchainStatusFound
                  : l10n.riscvToolchainStatusMissing,
              detail: entry.found
                  ? (entry.version ?? l10n.riscvToolchainVersionUnknown)
                  : guidance(l10n, entry.component, platform),
              footnote: _footnote(l10n, entry.component),
            ),
          ),
        Text(
          l10n.riscvToolchainNoBundlingNote,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  String? _footnote(L10N l10n, RiscvToolchainComponent component) {
    switch (component) {
      case RiscvToolchainComponent.pythonRiscof:
        return l10n.riscvToolchainOptionalRiscof;
      case RiscvToolchainComponent.formalEngine:
        return l10n.riscvToolchainOptionalFormal;
      case RiscvToolchainComponent.crossCompiler:
      case RiscvToolchainComponent.referenceModel:
        return null;
    }
  }

  /// The localized display name for [component].
  ///
  /// Static so the locale sweep can assert the matrix is complete without
  /// building the widget for every combination.
  static String componentLabel(
    L10N l10n,
    RiscvToolchainComponent component,
  ) => switch (component) {
    RiscvToolchainComponent.crossCompiler => l10n.riscvComponentCrossCompiler,
    RiscvToolchainComponent.referenceModel => l10n.riscvComponentReferenceModel,
    RiscvToolchainComponent.pythonRiscof => l10n.riscvComponentPythonRiscof,
    RiscvToolchainComponent.formalEngine => l10n.riscvComponentFormalEngine,
  };

  /// The localized, per-platform remediation for [component].
  ///
  /// Covers the same 4 × 3 matrix as
  /// `RiscvToolchainProbe.remediationFor`, and says the same thing. Where
  /// the honest answer is "use WSL2" it says so plainly rather than
  /// implying a native path that does not work.
  static String guidance(
    L10N l10n,
    RiscvToolchainComponent component,
    RiscvHostPlatform platform,
  ) {
    switch (component) {
      case RiscvToolchainComponent.crossCompiler:
        return switch (platform) {
          RiscvHostPlatform.linux => l10n.riscvGuidanceCrossCompilerLinux,
          RiscvHostPlatform.macos => l10n.riscvGuidanceCrossCompilerMacos,
          RiscvHostPlatform.windows => l10n.riscvGuidanceCrossCompilerWindows,
        };
      case RiscvToolchainComponent.referenceModel:
        return switch (platform) {
          RiscvHostPlatform.linux => l10n.riscvGuidanceReferenceModelLinux,
          RiscvHostPlatform.macos => l10n.riscvGuidanceReferenceModelMacos,
          RiscvHostPlatform.windows => l10n.riscvGuidanceReferenceModelWindows,
        };
      case RiscvToolchainComponent.pythonRiscof:
        return switch (platform) {
          RiscvHostPlatform.linux => l10n.riscvGuidanceRiscofLinux,
          RiscvHostPlatform.macos => l10n.riscvGuidanceRiscofMacos,
          RiscvHostPlatform.windows => l10n.riscvGuidanceRiscofWindows,
        };
      case RiscvToolchainComponent.formalEngine:
        return switch (platform) {
          RiscvHostPlatform.linux => l10n.riscvGuidanceFormalEngineLinux,
          RiscvHostPlatform.macos => l10n.riscvGuidanceFormalEngineMacos,
          RiscvHostPlatform.windows => l10n.riscvGuidanceFormalEngineWindows,
        };
    }
  }
}

class _ComponentTile extends StatelessWidget {
  const _ComponentTile({
    required this.entry,
    required this.label,
    required this.status,
    required this.detail,
    required this.footnote,
  });

  final RiscvComponentReport entry;
  final String label;
  final String status;
  final String detail;
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = entry.found
        ? theme.colorScheme.primary
        : theme.colorScheme.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Wrap rather than Row: the CJK locales run these labels long and a
        // Row would overflow at a narrow diagnostics width.
        Wrap(
          spacing: 8,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Icon(
              entry.found ? Icons.check_circle_outline : Icons.error_outline,
              size: 16,
              color: colour,
            ),
            Text(label, style: theme.textTheme.bodyMedium),
            Text(
              status,
              style: theme.textTheme.labelSmall?.copyWith(color: colour),
            ),
            Text(
              entry.binary,
              style: theme.textTheme.labelSmall?.copyWith(
                fontFamily: 'monospace',
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2, left: 24),
          child: Text(detail, style: theme.textTheme.bodySmall),
        ),
        if (footnote != null)
          Padding(
            padding: const EdgeInsets.only(top: 2, left: 24),
            child: Text(
              footnote!,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}
