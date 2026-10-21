// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/features/settings/widgets/settings_engine_rows.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
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
/// registers. It renders nothing while none is registered, so the group never
/// shows as an empty card.
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
    return SettingsEngineGroup(
      title: L10N.of(context).settingsImplementationFlowSection,
      rows: [
        for (final id in kImplementationFlowEngineIds)
          if (registered.contains(id))
            SettingsBinaryPathRow(engineId: id, settings: settings),
      ],
    );
  }
}
