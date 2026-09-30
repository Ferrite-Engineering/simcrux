// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/core/help_urls.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/features/remote/providers/cxp_discovery_provider.dart';
import 'package:simcrux/features/remote/providers/cxp_server_provider.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Settings → CXP Cross-Probe section: enable/disable the SimCrux CXP
/// server and pick the listening port.
///
/// SimCrux's CXP server lets other Crux apps (WaveCrux, NetCrux,
/// LintCrux) and any third-party CXP-aware tool gossip selection
/// events and dispatch "Debug in WaveCrux" requests.
///
/// The controls themselves are the suite-shared [CruxCxpSettingsControls]
/// (crux_cxp_ui) — this widget supplies SimCrux's provider wiring,
/// localized strings, and the running-state / peer-count status tile.
class SettingsRemoteControlSection extends ConsumerWidget {
  /// Creates a [SettingsRemoteControlSection].
  const SettingsRemoteControlSection({required this.settings, super.key});

  /// Currently-loaded [AppSettings].
  final AppSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final theme = Theme.of(context);
    final notifier = ref.read(appSettingsProvider.notifier);

    // Running state comes from the CXP server provider: it resolves to a
    // non-null server only while the "Enable CXP server" setting is on, so a
    // disabled server reads as Stopped. Peer count comes from the reactive
    // discovered-peers list the cross-probe panel also drives, so the count
    // updates live as peers appear/vanish.
    final isRunning = ref.watch(cxpServerProvider).value != null;
    final peerCount = ref.watch(cxpPeersProvider).length;

    return CruxCxpSettingsControls(
      strings: CruxCxpSettingsStrings(
        enableLabel: l10n.settingsCxpEnabledLabel,
        enableHelp: l10n.settingsCxpEnabledDescription,
        portLabel: l10n.settingsCxpPortLabel,
        portHelp: l10n.settingsCxpPortDescription,
        portError: l10n.settingsCxpPortError,
        attentionLabel: l10n.settingsRequestAttentionOnCrossProbeLabel,
        attentionHelp: l10n.settingsRequestAttentionOnCrossProbeDescription,
        broadcastLabel: l10n.settingsBroadcastSelectionOnCrossProbeLabel,
        broadcastHelp: l10n.settingsBroadcastSelectionOnCrossProbeDescription,
      ),
      enabled: settings.cxpServerEnabled,
      port: settings.cxpServerPort,
      requestAttention: settings.requestAttentionOnCrossProbe,
      broadcastSelection: settings.broadcastSelectionOnCrossProbe,
      onEnabledChanged: (value) =>
          unawaited(notifier.updateCxpServerEnabled(enabled: value)),
      onPortSubmitted: (port) => unawaited(notifier.updateCxpServerPort(port)),
      onRequestAttentionChanged: (value) => unawaited(
        notifier.updateRequestAttentionOnCrossProbe(enabled: value),
      ),
      onBroadcastSelectionChanged: (value) => unawaited(
        notifier.updateBroadcastSelectionOnCrossProbe(enabled: value),
      ),
      // CXP Status — running state + connected-peer count.
      statusTile: ListTile(
        contentPadding: EdgeInsets.zero,
        title: Row(
          children: [
            Flexible(
              child: Text(
                l10n.settingsCxpStatus,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            CruxHelpLink(
              url: HelpUrls.integrations,
              tooltip: l10n.helpLinkLearnMore,
            ),
          ],
        ),
        subtitle: Text(
          isRunning
              ? l10n.settingsCxpPeersConnected(peerCount)
              : l10n.settingsCxpStatusStopped,
        ),
        trailing: Text(
          isRunning
              ? l10n.settingsCxpStatusRunning(settings.cxpServerPort)
              : l10n.settingsCxpStatusStopped,
          style: TextStyle(
            color: isRunning
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
