// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/features/settings/widgets/settings_engine_rows.dart';
import 'package:simcrux/features/settings/widgets/settings_formal_tools_section.dart';
import 'package:simcrux/features/settings/widgets/settings_implementation_flow_section.dart';
import 'package:simcrux/features/settings/widgets/settings_simulators_section.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// The body of the Settings > Engines category: Simulators, then Formal
/// tools, then Implementation flow, each in its own card.
///
/// The last two render nothing until this build registers one of their
/// engines.
class SettingsEnginesSection extends StatelessWidget {
  /// Creates a [SettingsEnginesSection].
  const SettingsEnginesSection({required this.settings, super.key});

  /// Currently-loaded [AppSettings].
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsEngineGroup(
          title: L10N.of(context).settingsSimulatorsSection,
          leadingGap: false,
          rows: [SettingsSimulatorsSection(settings: settings)],
        ),
        SettingsFormalToolsSection(settings: settings),
        SettingsImplementationFlowSection(settings: settings),
      ],
    );
  }
}
