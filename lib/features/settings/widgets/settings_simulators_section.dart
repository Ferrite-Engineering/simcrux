// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:crux_settings_ui/crux_settings_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/core/help_urls.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/settings/widgets/settings_engine_rows.dart';
import 'package:simcrux/features/settings/widgets/settings_formal_tools_section.dart';
import 'package:simcrux/features/settings/widgets/settings_implementation_flow_section.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';

/// The engine ids that have their own group in Settings > Engines, and so
/// are left out of the Simulators group.
const Set<String> kEngineIdsOutsideSimulators = <String>{
  ...kFormalToolEngineIds,
  ...kImplementationFlowEngineIds,
};

/// The Simulators group of Settings > Engines: a binary path override for
/// every registered simulator, the app-wide simulator budget, and the
/// project-tooling consent switch.
///
/// Lists every driver id the registry advertises except the formal and
/// implementation-flow engines ([kEngineIdsOutsideSimulators]), which get
/// their rows in their own groups.
class SettingsSimulatorsSection extends ConsumerWidget {
  /// Creates a [SettingsSimulatorsSection].
  const SettingsSimulatorsSection({required this.settings, super.key});

  /// Currently-loaded [AppSettings].
  final AppSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final registry = ref.watch(simulatorDriverRegistryProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final id in registry.simulatorIds)
          if (!kEngineIdsOutsideSimulators.contains(id))
            SettingsBinaryPathRow(engineId: id, settings: settings),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  l10n.settingsSimulatorBinaryLabel,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              CruxHelpLink(
                url: HelpUrls.projectsAndSimulators,
                tooltip: l10n.helpLinkLearnMore,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // The process-wide simulator budget. Each run has 4 slots of its
        // own; this is the total every run draws from, so N tabs running at
        // once cannot spawn 4N simulators. See `AppSettings.maxTotalSimulators`.
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          l10n.settingsMaxTotalSimulatorsLabel,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 4),
                      CruxHelpLink(
                        url: HelpUrls.runningTests,
                        tooltip: l10n.helpLinkLearnMore,
                      ),
                    ],
                  ),
                  Text(
                    l10n.settingsMaxTotalSimulatorsDescription,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 72,
              child: _TotalSimulatorsField(
                key: const Key('settings.maxTotalSimulators'),
                initial: settings.maxTotalSimulators,
                onSubmit: (total) => unawaited(
                  ref
                      .read(appSettingsProvider.notifier)
                      .setMaxTotalSimulators(total),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        // Off by default, by design. `simulators.<id>.path`,
        // `simulators.<id>.env` and the `riscv.*.command` argv lists all
        // decide what SimCrux executes, so honoring them makes opening a
        // downloaded `.yaml` a code-execution decision the user never
        // made. See `AppSettings.allowProjectDefinedTooling`.
        Row(
          children: [
            Expanded(
              child: CruxFormRow.toggle(
                key: const Key('settings.allowProjectDefinedTooling'),
                label: l10n.settingsAllowProjectDefinedToolingLabel,
                help: l10n.settingsAllowProjectDefinedToolingDescription,
                value: settings.allowProjectDefinedTooling,
                onChanged: (enabled) => unawaited(
                  ref
                      .read(appSettingsProvider.notifier)
                      .setAllowProjectDefinedTooling(enabled: enabled),
                ),
              ),
            ),
            const SizedBox(width: 4),
            CruxHelpLink(
              url: HelpUrls.projectsAndSimulators,
              tooltip: l10n.helpLinkLearnMore,
            ),
          ],
        ),
      ],
    );
  }
}

/// The whole-app simulator budget, as a small integer field.
///
/// Submits on Enter or when focus leaves; a value that is not a whole number
/// is put back to what was stored, so a stray keystroke cannot silently
/// become a budget of one or of nothing.
class _TotalSimulatorsField extends StatefulWidget {
  const _TotalSimulatorsField({
    required this.initial,
    required this.onSubmit,
    super.key,
  });

  final int initial;
  final ValueChanged<int> onSubmit;

  @override
  State<_TotalSimulatorsField> createState() => _TotalSimulatorsFieldState();
}

class _TotalSimulatorsFieldState extends State<_TotalSimulatorsField> {
  late final TextEditingController _controller = TextEditingController(
    text: '${widget.initial}',
  );
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChange);
  }

  /// Submits when the user clicks away, the other way a number field is
  /// finished. Not during teardown: the node loses focus as the tree
  /// unmounts, and a submit there would persist whatever happened to be in
  /// the field.
  void _onFocusChange() {
    if (!mounted || _focus.hasFocus) return;
    _submit(_controller.text);
  }

  @override
  void didUpdateWidget(covariant _TotalSimulatorsField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The notifier clamps, so the stored value can differ from what was
    // typed; show what is in force.
    if (oldWidget.initial != widget.initial &&
        _controller.text != '${widget.initial}') {
      _controller.text = '${widget.initial}';
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit(String raw) {
    final parsed = int.tryParse(raw.trim());
    if (parsed == null) {
      _controller.text = '${widget.initial}';
      return;
    }
    // Enter both submits and unfocuses, so the blur listener sees the same
    // value a moment later; an unchanged value is not a second edit.
    if (parsed == widget.initial) return;
    widget.onSubmit(parsed);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focus,
      keyboardType: TextInputType.number,
      textAlign: TextAlign.end,
      decoration: const InputDecoration(isDense: true),
      onSubmitted: _submit,
    );
  }
}
