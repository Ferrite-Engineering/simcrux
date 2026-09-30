// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:crux_issue_reporter/crux_issue_reporter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/diagnostics/providers/riscv_toolchain_report_provider.dart';
import 'package:simcrux/features/diagnostics/widgets/riscv_toolchain_report_view.dart';
import 'package:simcrux/features/diagnostics/widgets/trend_store_recovery_card.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/trend_store/trend_store_provider.dart';

/// Process-wide App Diagnostics dialog, on the suite's converged shell
/// (640×480, localized title row + Copy + close ×, divider, scrollable
/// monospace body).
///
/// The report renders [cruxIssueSessionContextProvider] — the same
/// privacy-scrubbed contributor the beta issue reporter sends (counts,
/// fixed enumeration values, never a path or design identifier). One
/// source means the dialog and a filed issue can never disagree; matches
/// NetCrux/LintCrux.
class AppDiagnosticsDialog extends ConsumerWidget {
  /// Creates an [AppDiagnosticsDialog].
  const AppDiagnosticsDialog({super.key});

  /// Convenience launcher: show the dialog modally.
  ///
  /// Re-entrancy guarded ([ModalGuard]) inside the opener: shortcut
  /// auto-repeat, a double-tap on the menu item, or the palette entry must
  /// not stack a second dialog.
  static Future<void> show(BuildContext context) {
    return ModalGuard.run(
      'appDiagnostics',
      () => showDialog<void>(
        context: context,
        builder: (_) => const AppDiagnosticsDialog(),
      ),
    );
  }

  /// Renders [session] as the plain-text report body.
  static String reportFor(CruxIssueSessionContext session) {
    final buf = StringBuffer()
      ..writeln('# SimCrux App Diagnostics')
      ..writeln();
    if (session.isEmpty) {
      buf.writeln('(no session state available)');
      return buf.toString();
    }
    final width = session.fields
        .map((f) => f.label.length)
        .reduce((a, b) => a > b ? a : b);
    for (final field in session.fields) {
      buf.writeln('${field.label.padRight(width)}  ${field.value}');
    }
    return buf.toString();
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// SimCrux-specific report tail: the trend store's data-point / run
  /// counts and approximate on-disk size (the one section the retired
  /// bespoke dialog carried that the shared session context does not).
  String _trendStoreSection(WidgetRef ref, L10N l10n) {
    final stats = ref.watch(trendStorageStatsProvider);
    final line = switch (stats) {
      AsyncData(:final value) when value.dataPointCount == 0 =>
        l10n.diagnosticsTrendStoreEmpty,
      AsyncData(:final value) => l10n.diagnosticsTrendStoreSummary(
        value.dataPointCount,
        value.runCount,
        value.approximateBytes != null
            ? _formatBytes(value.approximateBytes!)
            : l10n.diagnosticsTrendStoreSizeUnknown,
      ),
      AsyncError(:final error) => '$error',
      _ => '…',
    };
    return '\n${l10n.diagnosticsTrendStoreSection}\n  $line\n'
        '${_schemaSection(ref, l10n)}';
  }

  /// The trend database's own account of itself, read from the shared
  /// `schema_meta` / `schema_migrations` shape `package:crux_sqlite` writes
  /// into every Crux SQLite database.
  ///
  /// Present here because this is the surface a support conversation is
  /// looking at when the question is "which build produced this file?" — a
  /// question nothing on disk could answer before schema v4. A file written by
  /// an older build records nothing, and says so; that is the normal state on
  /// the day this ships, not a fault.
  String _schemaSection(WidgetRef ref, L10N l10n) {
    final info = ref.watch(trendSchemaInfoProvider);
    final buf = StringBuffer('\n${l10n.diagnosticsTrendSchemaSection}\n');
    switch (info) {
      case AsyncData(:final value) when !value.isRecorded:
        buf.writeln('  ${l10n.diagnosticsTrendSchemaUnrecorded}');
      case AsyncData(:final value):
        buf
          ..writeln(
            '  ${l10n.diagnosticsTrendSchemaVersion(value.schemaVersion!)}',
          )
          ..writeln(
            '  ${l10n.diagnosticsTrendSchemaMigratedBy(
              value.migratedByAppVersion ?? l10n.diagnosticsTrendSchemaUnknown,
              value.lastMigratedAt?.toIso8601String() ?? l10n.diagnosticsTrendSchemaUnknown,
            )}',
          )
          ..writeln(
            '  ${l10n.diagnosticsTrendSchemaLastOpenedBy(
              value.lastOpenedByAppVersion ?? l10n.diagnosticsTrendSchemaUnknown,
            )}',
          );
        if (value.ledger.isNotEmpty) {
          buf.writeln('  ${l10n.diagnosticsTrendSchemaLedger}');
          for (final row in value.ledger) {
            buf.writeln(
              '    ${l10n.diagnosticsTrendSchemaLedgerRow(
                row.version,
                row.appliedAt?.toIso8601String() ?? l10n.diagnosticsTrendSchemaUnknown,
                row.appliedByAppVersion ?? l10n.diagnosticsTrendSchemaUnknown,
                row.description,
              )}',
            );
          }
        }
      case AsyncError(:final error):
        buf.writeln('  $error');
      case _:
        buf.writeln('  …');
    }
    return buf.toString();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final report =
        reportFor(ref.watch(cruxIssueSessionContextProvider)) +
        _trendStoreSection(ref, l10n);

    return Dialog(
      child: SizedBox(
        width: 640,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.diagnosticsAppDialogTitle,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy),
                    tooltip: l10n.diagnosticsCopyFullReport,
                    onPressed: () => _copy(context, report),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      report,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                    // Renders nothing unless this session's trend database
                    // was quarantined. It is here, above the RISC-V report,
                    // because it is the one part of this dialog that is not a
                    // status read-out: it carries the user's way back from a
                    // damaged `trends.db`.
                    const TrendStoreRecoveryCard(),
                    const SizedBox(height: 16),
                    // RISC-V toolchain. The one section of this dialog that
                    // is rendered rather than printed, because its content is
                    // actionable per-platform guidance and that has to be
                    // localized — the plain-text remediation strings on
                    // RiscvComponentReport are the log-facing channel and stay
                    // unlocalized.
                    // Watched here and nowhere else, so the four probe
                    // subprocesses are only ever paid for when this dialog is
                    // actually opened.
                    switch (ref.watch(riscvToolchainReportProvider)) {
                      AsyncData(:final value) => RiscvToolchainReportView(
                        report: value,
                        platform: ref.watch(riscvHostPlatformProvider),
                      ),
                      _ => const SizedBox.shrink(),
                    },
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _copy(BuildContext context, String report) {
    final l10n = L10N.of(context);
    unawaited(Clipboard.setData(ClipboardData(text: report)));
    showCruxInfoSnack(context, l10n.diagnosticsCopiedToClipboard);
  }
}
