// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:crux_settings_ui/crux_settings_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/core/help_urls.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/features/inspector/providers/log_preview_settings_provider.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Auto-reload-mode + log-preview-line-count knobs.
class SettingsGeneralSection extends ConsumerWidget {
  /// Creates a [SettingsGeneralSection].
  const SettingsGeneralSection({
    required this.settings,
    this.showDiagnosticsToggle = kReleaseMode,
    super.key,
  });

  /// The currently-loaded [AppSettings].
  final AppSettings settings;

  /// Whether to show the diagnostics opt-in. Debug and profile builds force
  /// the diagnostics surfaces on (`diagnosticsEnabledProvider`), so the
  /// switch would be inert there and is shown only in release builds.
  final bool showDiagnosticsToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The suite-shared control: segmented prompt / auto / off in
        // canonical order (this app previously used a dropdown — the only
        // one of the four presenting the enum that way).
        CruxAutoReloadSettingTile(
          label: l10n.settingsAutoReloadLabel,
          description: l10n.settingsAutoReloadDescription,
          value: settings.autoReloadMode,
          onChanged: (mode) => unawaited(
            ref.read(appSettingsProvider.notifier).updateAutoReloadMode(mode),
          ),
          promptLabel: l10n.settingsAutoReloadPrompt,
          autoLabel: l10n.settingsAutoReloadAuto,
          offLabel: l10n.settingsAutoReloadOff,
        ),
        const SizedBox(height: 16),
        // The suite-shared slider tile (label/description stacked above the
        // slider + fixed value readout), replacing a hand-rolled Row.
        CruxSettingsSliderTile(
          title: l10n.settingsLogPreviewLineCountLabel,
          description: l10n.settingsLogPreviewLineCountDescription,
          value: settings.inspectorLogPreviewLineCount.toDouble().clamp(
            kMinInspectorLogPreviewLineCount.toDouble(),
            kMaxInspectorLogPreviewLineCount.toDouble(),
          ),
          min: kMinInspectorLogPreviewLineCount.toDouble(),
          max: kMaxInspectorLogPreviewLineCount.toDouble(),
          divisions: 49,
          label: settings.inspectorLogPreviewLineCount.toString(),
          valueText: settings.inspectorLogPreviewLineCount.toString(),
          onChanged: (value) => unawaited(
            ref
                .read(appSettingsProvider.notifier)
                .updateInspectorLogPreviewLineCount(value.round()),
          ),
        ),
        const SizedBox(height: 16),
        // Off by default, by design: opening a config must not launch
        // the whole regression. See `AppSettings.autoRunOnOpen`.
        SwitchListTile(
          key: const Key('settings.autoRunOnOpen'),
          contentPadding: EdgeInsets.zero,
          value: settings.autoRunOnOpen,
          title: Row(
            children: [
              // Flexible so the label shrinks (and ellipsises) before the
              // help icon trailing the row gets pushed off-screen on narrow
              // viewports (the WaveCrux settings help-link pattern).
              Flexible(
                child: Text(
                  l10n.settingsAutoRunOnOpenLabel,
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
          subtitle: Text(l10n.settingsAutoRunOnOpenDescription),
          onChanged: (enabled) {
            unawaited(
              ref
                  .read(appSettingsProvider.notifier)
                  .updateAutoRunOnOpen(enabled: enabled),
            );
          },
        ),
        const SizedBox(height: 16),
        // Gates every *scheduled* update check (launch, 24 h periodic, on
        // resume) via `crux_updates`' `autoUpdateCheckEnabledProvider`. The
        // manual Help → Check for Updates action ignores it by contract.
        // SwitchListTile's default vertical padding already clears the
        // suite's 44 dp minimum touch target.
        SwitchListTile(
          key: const Key('settings.autoCheckForUpdates'),
          contentPadding: EdgeInsets.zero,
          value: settings.autoCheckForUpdates,
          title: Text(l10n.settingsAutoCheckUpdatesLabel),
          subtitle: Text(l10n.settingsAutoCheckUpdatesDescription),
          onChanged: (enabled) {
            unawaited(
              ref
                  .read(appSettingsProvider.notifier)
                  .updateAutoCheckForUpdates(enabled: enabled),
            );
          },
        ),
        if (showDiagnosticsToggle) ...[
          const SizedBox(height: 16),
          SwitchListTile(
            key: const Key('settings.diagnosticsEnabled'),
            contentPadding: EdgeInsets.zero,
            value: settings.diagnosticsEnabled,
            title: Text(l10n.settingsDiagnosticsEnabledLabel),
            subtitle: Text(l10n.settingsDiagnosticsEnabledDescription),
            onChanged: (enabled) {
              unawaited(
                ref
                    .read(appSettingsProvider.notifier)
                    .updateDiagnosticsEnabled(enabled: enabled),
              );
            },
          ),
        ],
      ],
    );
  }
}
