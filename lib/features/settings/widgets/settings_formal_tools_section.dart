// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/core/help_urls.dart';
import 'package:simcrux/domain/enums/riscv_host_platform.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/domain/models/formal_toolchain_report.dart';
import 'package:simcrux/features/settings/widgets/settings_engine_rows.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/formal/formal_toolchain_probe.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';

/// The formal engine ids whose binary paths are set under Formal tools
/// rather than Simulators.
///
/// The Simulators group lists every other registered driver id, so an id
/// listed here appears in exactly one group.
const List<String> kFormalToolEngineIds = <String>['sby', 'eqy'];

/// The probe the Formal tools group runs. A provider so tests answer it
/// without spawning anything.
final Provider<FormalToolchainProbe> formalToolchainProbeProvider =
    Provider<FormalToolchainProbe>((ref) => FormalToolchainProbe());

/// The Formal tools group of Settings > Engines.
///
/// One binary-path row for each formal engine this build registers, then
/// Check Formal Tools, which runs [FormalToolchainProbe] and lists what it
/// found. Every other tool (Yosys, the plugin, the solvers) is looked up
/// beside the `sby` set here, which is how an OSS CAD Suite lays them out;
/// a job file that needs another is given one with `formal.tools` in the
/// project. It renders nothing while no formal engine is registered, so
/// the group never shows as an empty card.
class SettingsFormalToolsSection extends ConsumerWidget {
  /// Creates a [SettingsFormalToolsSection].
  const SettingsFormalToolsSection({required this.settings, super.key});

  /// Currently-loaded [AppSettings].
  final AppSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final registered = ref
        .watch(simulatorDriverRegistryProvider)
        .simulatorIds
        .toSet();
    final engines = <String>[
      for (final id in kFormalToolEngineIds)
        if (registered.contains(id)) id,
    ];
    return SettingsEngineGroup(
      title: L10N.of(context).settingsFormalToolsSection,
      rows: [
        for (final id in engines)
          SettingsBinaryPathRow(engineId: id, settings: settings),
        if (engines.isNotEmpty) FormalToolchainCheck(settings: settings),
      ],
    );
  }
}

/// Check Formal Tools and the report it produces.
class FormalToolchainCheck extends ConsumerStatefulWidget {
  /// Creates the check.
  const FormalToolchainCheck({required this.settings, super.key});

  /// Currently-loaded [AppSettings]: the `sby` and `eqy` paths the probe
  /// starts from.
  final AppSettings settings;

  @override
  ConsumerState<FormalToolchainCheck> createState() =>
      _FormalToolchainCheckState();
}

class _FormalToolchainCheckState extends ConsumerState<FormalToolchainCheck> {
  FormalToolchainReport? _report;
  bool _running = false;

  Future<void> _check() async {
    final probe = ref.read(formalToolchainProbeProvider);
    final overrides = widget.settings.simulatorBinaryOverrides;
    setState(() => _running = true);
    final report = await probe.probe(
      sbyPath: overrides['sby'],
      eqyPath: overrides['eqy'],
    );
    if (!mounted) return;
    setState(() {
      _running = false;
      _report = report;
    });
    final l10n = L10N.of(context);
    announceCrux(
      context,
      report.missing.isEmpty
          ? l10n.settingsFormalToolsAllFound
          : l10n.settingsFormalToolsSomeMissing(report.missing.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    final theme = Theme.of(context);
    final report = _report;
    final probe = ref.watch(formalToolchainProbeProvider);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              OutlinedButton(
                key: const ValueKey('formalToolsCheck'),
                onPressed: _running ? null : () => unawaited(_check()),
                child: Text(l10n.settingsFormalToolsCheck),
              ),
              const SizedBox(width: 4),
              CruxHelpLink(
                url: HelpUrls.formalTools,
                tooltip: l10n.helpLinkLearnMore,
              ),
              if (_running) ...[
                const SizedBox(width: 12),
                Text(
                  l10n.settingsFormalToolsChecking,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
          ),
          if (report != null) ...[
            const SizedBox(height: 8),
            for (final row in report.tools)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ExcludeSemantics(
                      child: Icon(
                        row.found ? Icons.check_circle_outline : Icons.cancel,
                        size: 16,
                        color: row.found
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        formalToolLine(l10n, row),
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            if (report.missing.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                formalToolGuidance(l10n, probe.platform),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// One report row as a sentence: the tool, then what was found. The words
/// carry the result, so the glyph beside it is decoration.
String formalToolLine(L10N l10n, FormalToolReport row) {
  final name = row.tool.binaryName;
  if (!row.found) return l10n.settingsFormalToolsMissing(name);
  final version = row.version;
  if (row.tool == FormalTool.yosys && version != null) {
    return row.verific ?? false
        ? l10n.settingsFormalToolsYosysWithVerific(name, version)
        : l10n.settingsFormalToolsYosysWithoutVerific(name, version);
  }
  return version == null
      ? l10n.settingsFormalToolsFound(name)
      : l10n.settingsFormalToolsFoundVersion(name, version);
}

/// Where to get the missing tools on [platform].
String formalToolGuidance(L10N l10n, RiscvHostPlatform platform) =>
    switch (platform) {
      RiscvHostPlatform.linux => l10n.settingsFormalToolsGuidanceLinux,
      RiscvHostPlatform.macos => l10n.settingsFormalToolsGuidanceMacos,
      RiscvHostPlatform.windows => l10n.settingsFormalToolsGuidanceWindows,
    };
