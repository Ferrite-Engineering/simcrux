// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_settings_ui/crux_settings_ui.dart';
import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/settings/providers/settings_extensions.dart';
import 'package:simcrux/features/settings/widgets/color_theme_section.dart';
import 'package:simcrux/features/settings/widgets/settings_detectors_section.dart';
import 'package:simcrux/features/settings/widgets/settings_editor_section.dart';
import 'package:simcrux/features/settings/widgets/settings_general_section.dart';
import 'package:simcrux/features/settings/widgets/settings_remote_control_section.dart';
import 'package:simcrux/features/settings/widgets/settings_simulators_section.dart';
import 'package:simcrux/features/settings/widgets/shortcuts_settings_section.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Top-level Settings screen.
///
/// Four sections:
///
/// - General: auto-reload mode, default log preview line count.
/// - Appearance: color-theme preset (brightness follows the preset).
/// - Simulators: per-simulator binary path override + default options.
/// - Editors: editor command template + presets.
///
/// On desktop the menu / shortcut dispatch hosts [SettingsBody]
/// directly inside a [DesktopDialog] (see `app.dart`). This screen
/// wraps [SettingsBody] in a [Scaffold] + [AppBar] so the legacy
/// `/settings` deep-link route still resolves with its own chrome.
class SettingsScreen extends ConsumerWidget {
  /// Creates a [SettingsScreen].
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    return CruxSettingsRouteShell(
      title: l10n.settingsTitle,
      closeTooltip: l10n.dialogClose,
      body: const SettingsBody(),
    );
  }
}

/// Chrome-less Settings content. Hosted inside the [SettingsScreen]
/// route's Scaffold and inside the [DesktopDialog] surface — same
/// widget either way so the two entry points stay in lockstep.
class SettingsBody extends ConsumerWidget {
  /// Creates a [SettingsBody].
  const SettingsBody({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final asyncSettings = ref.watch(appSettingsProvider);
    final extraSections = ref.watch(extraSettingsSectionsProvider);
    return asyncSettings.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text(l10n.settingsLoadFailed('$e'))),
      data: (settings) => CruxSettingsMasterDetail(
        categories: [
          CruxSettingsCategory(
            id: CruxSettingsCategoryId.general,
            icon: Icons.tune,
            title: l10n.settingsGeneralSection,
            content: _card(SettingsGeneralSection(settings: settings)),
          ),
          // Appearance: color preset only. Brightness follows the color
          // preset (WaveCrux model). There is no system/light/dark selector:
          // it would write AppSettings.themeMode, which MaterialApp never
          // reads.
          CruxSettingsCategory(
            id: CruxSettingsCategoryId.appearance,
            icon: Icons.palette_outlined,
            title: l10n.settingsAppearanceSection,
            content: _card(
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // The shared suite Language picker — the four shipped
                  // locales were unreachable in SimCrux before this (no
                  // picker, and the persisted CoreSettings.locale was never
                  // applied).
                  CruxLocaleSettingTile(
                    label: l10n.settingsLanguageLabel,
                    description: l10n.settingsLanguageDescription,
                    locale: settings.core.locale,
                    onChanged: (v) =>
                        ref.read(appSettingsProvider.notifier).setLocale(v),
                  ),
                  const ColorThemeSection(),
                ],
              ),
            ),
          ),
          // Privacy sits third — as high as the suite-canonical "General
          // leads, then Appearance" order allows. It holds the telemetry
          // opt-out, and the off switch must not be buried; a section the
          // user has to scroll a rail to find is buried.
          //
          // Offered only on a build whose pipeline can actually transmit:
          // during the beta with no dev flag the Settings screen is exactly
          // what it was before telemetry existed — the telemetry dark launch,
          // extended to the UI. A build incapable of collecting must not
          // advertise an opt-out.
          //
          // The section itself is `crux_telemetry`'s, so all four products'
          // opt-out is one implementation; only the category placement and the
          // localized heading are SimCrux's.
          if (ref.watch(telemetryConsentUiVisibleProvider))
            CruxSettingsCategory(
              id: CruxSettingsCategoryId.privacy,
              icon: Icons.privacy_tip_outlined,
              title: l10n.settingsPrivacySection,
              content: const TelemetrySettingsSection(),
            ),
          // The third rail slot is the suite's shared `productDefaults` — one id,
          // four product titles. SimCrux titles it "Simulators"; WaveCrux
          // titles the same slot "Waveform defaults". There is deliberately no
          // `simulators` id: shared code must not carry a single-product
          // domain noun.
          CruxSettingsCategory(
            id: CruxSettingsCategoryId.productDefaults,
            // memory is the suite's engines/simulators icon (NetCrux and
            // LintCrux Engines use it) — external engine binaries either way.
            icon: Icons.memory,
            title: l10n.settingsSimulatorsSection,
            content: _card(SettingsSimulatorsSection(settings: settings)),
          ),
          CruxSettingsCategory(
            id: CruxSettingsCategoryId.editors,
            icon: Icons.edit_outlined,
            title: l10n.settingsEditorsSection,
            content: _card(SettingsEditorSection(settings: settings)),
          ),
          CruxSettingsCategory(
            id: CruxSettingsCategoryId.cxp,
            // hub_outlined is the suite's CXP icon (wifi_tethering is
            // WaveCrux's WCP Remote Control).
            icon: Icons.hub_outlined,
            title: l10n.settingsCxpSectionTitle,
            content: _card(SettingsRemoteControlSection(settings: settings)),
          ),
          CruxSettingsCategory(
            id: CruxSettingsCategoryId.detectors,
            icon: Icons.rule,
            title: l10n.settingsDetectorsSection,
            content: _card(SettingsDetectorsSection(settings: settings)),
          ),
          // Not card-wrapped: ShortcutsSettingsSection (KeyBindingsEditor) is a
          // self-styled editor that supplies its own section padding.
          CruxSettingsCategory(
            id: CruxSettingsCategoryId.shortcuts,
            icon: Icons.keyboard_outlined,
            title: l10n.settingsShortcutsSection,
            content: const ShortcutsSettingsSection(),
          ),
          // Overlay-injected sections (Pro overlay's Flaky Test Detection,
          // future trend-tracking knobs, etc.). Default open-core list is
          // empty so nothing renders here in a free build.
          //
          // `toCategory` is the seam's own conversion, and using it is the
          // point: it carries each entry's stable `pro.*` id through, which is
          // what lets the conformance test assert Pro extras follow all the
          // canonical categories rather than interleaving. SimCrux used to
          // hand-rebuild the category here and wrap the body in `_card`, so a
          // Pro-contributed section rendered in a card in SimCrux and bare in
          // the other three — a divergence on the ONE extension seam. The card
          // is the contributing section's decision to make (WaveCrux's Pro
          // Collaboration section returns its own `CruxSettingsCard`), so the
          // wrapping moved into the Pro overlay's body builders.
          for (final ext in extraSections) ext.toCategory(context),
        ],
      ),
    );
  }
}

/// Wraps a settings section's content in the suite-shared
/// [CruxSettingsSectionCard] (grouped card + uniform 16 dp interior padding;
/// the header that used to sit above them now lives in the shell title).
Widget _card(Widget child) => CruxSettingsSectionCard(children: [child]);
