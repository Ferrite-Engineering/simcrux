// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/core/help_urls.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';

/// Per-simulator binary path override section. Lists every simulator
/// the driver registry advertises and lets the user supply an
/// absolute path to a non-PATH binary.
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
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 120,
                  child: Text(id),
                ),
                Expanded(
                  child: _BinaryPathField(
                    simulatorId: id,
                    initial: settings.simulatorBinaryOverrides[id] ?? '',
                    onSubmit: (value) {
                      final next = Map<String, String>.from(
                        settings.simulatorBinaryOverrides,
                      );
                      if (value.isEmpty) {
                        next.remove(id);
                      } else {
                        next[id] = value;
                      }
                      unawaited(
                        ref
                            .read(appSettingsProvider.notifier)
                            .updateSimulatorBinaryOverrides(next),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
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
        // Off by default, by design. `simulators.<id>.path`,
        // `simulators.<id>.env` and the `riscv.*.command` argv lists all
        // decide what SimCrux executes, so honoring them makes opening a
        // downloaded `.yaml` a code-execution decision the user never
        // made. See `AppSettings.allowProjectDefinedTooling`.
        SwitchListTile(
          key: const Key('settings.allowProjectDefinedTooling'),
          contentPadding: EdgeInsets.zero,
          value: settings.allowProjectDefinedTooling,
          title: Row(
            children: [
              // Flexible so the label ellipsises before the trailing help
              // icon is pushed off-screen on a narrow viewport.
              Flexible(
                child: Text(
                  l10n.settingsAllowProjectDefinedToolingLabel,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              CruxHelpLink(
                url: HelpUrls.projectsAndSimulators,
                tooltip: l10n.helpLinkLearnMore,
              ),
            ],
          ),
          subtitle: Text(l10n.settingsAllowProjectDefinedToolingDescription),
          onChanged: (enabled) => unawaited(
            ref
                .read(appSettingsProvider.notifier)
                .setAllowProjectDefinedTooling(enabled: enabled),
          ),
        ),
      ],
    );
  }
}

class _BinaryPathField extends StatefulWidget {
  const _BinaryPathField({
    required this.simulatorId,
    required this.initial,
    required this.onSubmit,
  });

  final String simulatorId;
  final String initial;
  final ValueChanged<String> onSubmit;

  @override
  State<_BinaryPathField> createState() => _BinaryPathFieldState();
}

class _BinaryPathFieldState extends State<_BinaryPathField> {
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
    return TextField(
      controller: _controller,
      decoration: const InputDecoration(
        isDense: true,
        hintText: r'/usr/local/bin (leave empty to use $PATH)',
      ),
      onSubmitted: widget.onSubmit,
    );
  }
}
