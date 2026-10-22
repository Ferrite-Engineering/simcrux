// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:crux_settings_ui/crux_settings_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/domain/models/flow_tool_settings.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/settings/widgets/settings_engine_rows.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/flow/flow_toolchain_probe.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';

/// The implementation-flow engine ids whose binary paths are set under
/// Implementation flow rather than Simulators.
///
/// The Simulators group lists every other registered driver id, so an id
/// listed here appears in exactly one group.
const List<String> kImplementationFlowEngineIds = <String>[
  'librelane',
  'nextpnr',
];

/// The Implementation flow group of Settings > Engines.
///
/// One binary-path row for each implementation-flow engine this build
/// registers (the LibreLane path; the directory holding nextpnr and its
/// Yosys), then the rest of [AppSettings.flowTools]: the LibreLane launcher
/// and Docker image, the PDK root, and the KLayout, OpenROAD and FuseSoC
/// paths. It renders nothing while no flow engine is registered, so the
/// group never shows as an empty card.
class SettingsImplementationFlowSection extends ConsumerWidget {
  /// Creates a [SettingsImplementationFlowSection].
  const SettingsImplementationFlowSection({required this.settings, super.key});

  /// Currently-loaded [AppSettings].
  final AppSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final registered = ref
        .watch(simulatorDriverRegistryProvider)
        .simulatorIds
        .toSet();
    final engines = <String>[
      for (final id in kImplementationFlowEngineIds)
        if (registered.contains(id)) id,
    ];
    return SettingsEngineGroup(
      title: L10N.of(context).settingsImplementationFlowSection,
      rows: [
        for (final id in engines)
          SettingsBinaryPathRow(engineId: id, settings: settings),
        if (engines.isNotEmpty) FlowToolSettingsRows(settings: settings),
        if (engines.isNotEmpty) FlowToolchainCheck(settings: settings),
      ],
    );
  }
}

/// The probe Check Flow Tools runs. A provider so tests answer it without
/// spawning anything.
final Provider<FlowToolchainProbe> flowToolchainProbeProvider =
    Provider<FlowToolchainProbe>((ref) => FlowToolchainProbe());

/// Check Flow Tools and the report it produces.
class FlowToolchainCheck extends ConsumerStatefulWidget {
  /// Creates the check.
  const FlowToolchainCheck({required this.settings, super.key});

  /// Currently-loaded [AppSettings]: the paths the probe starts from.
  final AppSettings settings;

  @override
  ConsumerState<FlowToolchainCheck> createState() => _FlowToolchainCheckState();
}

class _FlowToolchainCheckState extends ConsumerState<FlowToolchainCheck> {
  FlowToolchainReport? _report;
  bool _running = false;

  Future<void> _check() async {
    final probe = ref.read(flowToolchainProbeProvider);
    final overrides = widget.settings.simulatorBinaryOverrides;
    setState(() => _running = true);
    final report = await probe.probe(
      nextpnrPath: overrides['nextpnr'],
      librelanePath: overrides['librelane'],
      settings: widget.settings.flowTools,
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
          ? l10n.settingsFlowToolsAllFound
          : l10n.settingsFlowToolsSomeMissing(report.missing.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    final theme = Theme.of(context);
    final report = _report;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              OutlinedButton(
                key: const ValueKey('flowToolsCheck'),
                onPressed: _running ? null : () => unawaited(_check()),
                child: Text(l10n.settingsFlowToolsCheck),
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
              _ReportLine(
                found: row.found,
                text: !row.found
                    ? l10n.settingsFormalToolsMissing(row.tool.binaryName)
                    : row.version == null
                    ? l10n.settingsFormalToolsFound(row.tool.binaryName)
                    : l10n.settingsFormalToolsFoundVersion(
                        row.tool.binaryName,
                        row.version!,
                      ),
              ),
            _ReportLine(
              found: report.pdks.isNotEmpty,
              text: report.pdks.isEmpty
                  ? l10n.settingsFlowToolsNoPdk
                  : l10n.settingsFlowToolsPdks(report.pdks.join(', ')),
            ),
            if (report.missing.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                l10n.settingsFlowToolsGuidance,
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

/// One report line. The words carry the result; the glyph is decoration.
class _ReportLine extends StatelessWidget {
  const _ReportLine({required this.found, required this.text});

  final bool found;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: Icon(
              found ? Icons.check_circle_outline : Icons.cancel,
              size: 16,
              color: found
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}

/// The Implementation flow rows beyond the binary paths, each writing one
/// field of [AppSettings.flowTools].
class FlowToolSettingsRows extends ConsumerWidget {
  /// Creates the rows.
  const FlowToolSettingsRows({required this.settings, super.key});

  /// Currently-loaded [AppSettings].
  final AppSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final flow = settings.flowTools;
    void save(FlowToolSettings next) => unawaited(
      ref.read(appSettingsProvider.notifier).updateFlowTools(next),
    );
    FlowToolSettings copy({
      FlowLauncher? launcher,
      String? dockerImage,
      String? pdkRoot,
      String? klayoutPath,
      String? openroadPath,
      String? fusesocPath,
    }) => FlowToolSettings(
      launcher: launcher ?? flow.launcher,
      dockerImage: dockerImage ?? flow.dockerImage,
      pdkRoot: pdkRoot ?? flow.pdkRoot,
      klayoutPath: klayoutPath ?? flow.klayoutPath,
      openroadPath: openroadPath ?? flow.openroadPath,
      fusesocPath: fusesocPath ?? flow.fusesocPath,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CruxFormRow(
          label: l10n.settingsFlowLauncherLabel,
          mergeSemantics: false,
          child: CruxSegmentedControl<FlowLauncher>(
            key: const ValueKey('flowLauncher'),
            semanticLabel: l10n.settingsFlowLauncherLabel,
            selected: flow.launcher,
            segments: [
              CruxSegment(
                value: FlowLauncher.path,
                label: l10n.settingsFlowLauncherPath,
              ),
              CruxSegment(
                value: FlowLauncher.nix,
                label: l10n.settingsFlowLauncherNix,
              ),
              CruxSegment(
                value: FlowLauncher.docker,
                label: l10n.settingsFlowLauncherDocker,
              ),
            ],
            onChanged: (value) => save(copy(launcher: value)),
          ),
        ),
        _FlowTextRow(
          fieldKey: const ValueKey('flowDockerImage'),
          label: l10n.settingsFlowDockerImageLabel,
          hint: l10n.settingsFlowOptionalHint,
          initial: flow.dockerImage,
          onSubmit: (v) => save(copy(dockerImage: v)),
        ),
        _FlowTextRow(
          fieldKey: const ValueKey('flowPdkRoot'),
          label: l10n.settingsFlowPdkRootLabel,
          hint: l10n.settingsFlowOptionalHint,
          initial: flow.pdkRoot,
          onSubmit: (v) => save(copy(pdkRoot: v)),
        ),
        _FlowTextRow(
          fieldKey: const ValueKey('flowKlayoutPath'),
          label: l10n.settingsFlowKlayoutLabel,
          hint: l10n.settingsFlowPathHint,
          initial: flow.klayoutPath,
          onSubmit: (v) => save(copy(klayoutPath: v)),
        ),
        _FlowTextRow(
          fieldKey: const ValueKey('flowOpenroadPath'),
          label: l10n.settingsFlowOpenroadLabel,
          hint: l10n.settingsFlowPathHint,
          initial: flow.openroadPath,
          onSubmit: (v) => save(copy(openroadPath: v)),
        ),
        _FlowTextRow(
          fieldKey: const ValueKey('flowFusesocPath'),
          label: l10n.settingsFlowFusesocLabel,
          hint: l10n.settingsFlowPathHint,
          initial: flow.fusesocPath,
          onSubmit: (v) => save(copy(fusesocPath: v)),
        ),
      ],
    );
  }
}

class _FlowTextRow extends StatefulWidget {
  const _FlowTextRow({
    required this.fieldKey,
    required this.label,
    required this.hint,
    required this.initial,
    required this.onSubmit,
  });

  final Key fieldKey;
  final String label;
  final String hint;
  final String initial;
  final ValueChanged<String> onSubmit;

  @override
  State<_FlowTextRow> createState() => _FlowTextRowState();
}

class _FlowTextRowState extends State<_FlowTextRow> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CruxFormRow(
      label: widget.label,
      child: TextField(
        key: widget.fieldKey,
        controller: _controller,
        decoration: InputDecoration(isDense: true, hintText: widget.hint),
        onSubmitted: (value) => widget.onSubmit(value.trim()),
      ),
    );
  }
}
