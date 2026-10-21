// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/features/settings/widgets/settings_engine_rows.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';

/// The formal engine ids whose binary paths are set under Formal tools
/// rather than Simulators.
///
/// The Simulators group lists every other registered driver id, so an id
/// listed here appears in exactly one group.
const List<String> kFormalToolEngineIds = <String>['sby', 'eqy'];

/// The Formal tools group of Settings > Engines.
///
/// One binary-path row for each formal engine this build registers. It
/// renders nothing while none is registered, so the group never shows as an
/// empty card.
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
    return SettingsEngineGroup(
      title: L10N.of(context).settingsFormalToolsSection,
      rows: [
        for (final id in kFormalToolEngineIds)
          if (registered.contains(id))
            SettingsBinaryPathRow(engineId: id, settings: settings),
      ],
    );
  }
}
