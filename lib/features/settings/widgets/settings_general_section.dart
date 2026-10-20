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
        _TileAligned(
          child: Row(
            children: [
              Expanded(
                child: CruxFormRow.toggle(
                  key: const Key('settings.autoRunOnOpen'),
                  label: l10n.settingsAutoRunOnOpenLabel,
                  help: l10n.settingsAutoRunOnOpenDescription,
                  value: settings.autoRunOnOpen,
                  onChanged: (enabled) {
                    unawaited(
                      ref
                          .read(appSettingsProvider.notifier)
                          .updateAutoRunOnOpen(enabled: enabled),
                    );
                  },
                ),
              ),
              const SizedBox(width: 4),
              CruxHelpLink(
                url: HelpUrls.runningTests,
                tooltip: l10n.helpLinkLearnMore,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // Gates every *scheduled* update check (launch, 24 h periodic, on
        // resume) via `crux_updates`' `autoUpdateCheckEnabledProvider`. The
        // manual Help → Check for Updates action ignores it by contract.
        _TileAligned(
          child: CruxFormRow.toggle(
            key: const Key('settings.autoCheckForUpdates'),
            label: l10n.settingsAutoCheckUpdatesLabel,
            help: l10n.settingsAutoCheckUpdatesDescription,
            value: settings.autoCheckForUpdates,
            onChanged: (enabled) {
              unawaited(
                ref
                    .read(appSettingsProvider.notifier)
                    .updateAutoCheckForUpdates(enabled: enabled),
              );
            },
          ),
        ),
        if (showDiagnosticsToggle) ...[
          const SizedBox(height: 16),
          _TileAligned(
            child: CruxFormRow.toggle(
              key: const Key('settings.diagnosticsEnabled'),
              label: l10n.settingsDiagnosticsEnabledLabel,
              help: l10n.settingsDiagnosticsEnabledDescription,
              value: settings.diagnosticsEnabled,
              onChanged: (enabled) {
                unawaited(
                  ref
                      .read(appSettingsProvider.notifier)
                      .updateDiagnosticsEnabled(enabled: enabled),
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}

/// Insets a toggle row by the 16 dp each side the suite's shared settings
/// tiles (`CruxSettingsControlTile`, `CruxSettingsSliderTile`, the
/// auto-reload and language tiles) carry inside their own padding, so the
/// toggles' labels start where the other rows' labels do.
///
/// A bare `CruxFormRow.toggle` has no padding of its own, which put every
/// toggle about 16 dp to the left of the tiles above it.
class _TileAligned extends StatelessWidget {
  const _TileAligned({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: child,
  );
}
