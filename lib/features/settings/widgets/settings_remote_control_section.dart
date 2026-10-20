// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/core/help_urls.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Settings > CXP Cross-Probe section: enable/disable the SimCrux CXP
/// server and pick the listening port.
///
/// SimCrux's CXP server lets other Crux apps (WaveCrux, NetCrux,
/// LintCrux) and any third-party CXP-aware tool gossip selection
/// events and dispatch "Debug in WaveCrux" requests.
///
/// The controls and the status line are the suite-shared
/// [CruxCxpSettingsSection], bound to the shared CXP settings and runtime.
/// SimCrux adds only the help link beside it.
class SettingsRemoteControlSection extends ConsumerWidget {
  /// Creates a [SettingsRemoteControlSection].
  const SettingsRemoteControlSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const CruxCxpSettingsSection(),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: CruxHelpLink(
            url: HelpUrls.integrations,
            tooltip: l10n.helpLinkLearnMore,
          ),
        ),
      ],
    );
  }
}
