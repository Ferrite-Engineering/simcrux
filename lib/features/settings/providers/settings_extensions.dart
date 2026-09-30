// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_settings_ui/crux_settings_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Extension-point seam for the Pro overlay to inject additional
/// categories into the open-core `SettingsScreen` rail.
///
/// **Open-core default.** Returns an empty list — only the built-in
/// categories (General, Appearance, Simulators, Editors, CXP Cross-Probe,
/// Detectors, Keyboard Shortcuts) appear. The Pro overlay overrides this
/// provider in `proOverrides` with Flaky Test Detection, Parameterization,
/// Plugins, and Retention.
///
/// The entry type is the suite-shared [CruxSettingsExtraCategory]
/// (crux_settings_ui) — stable id, required icon, context-taking
/// label/body builders — replacing the app-local `SettingsSectionExtension`
/// (the suite settings consistency pass unified the three per-app seam
/// shapes).
///
/// **Why a Riverpod provider rather than a const list.** Pro categories
/// typically wrap a Riverpod-aware editor whose visibility depends on
/// the active license tier and the `FeatureGate` check — surfacing
/// them through a provider means the Settings screen rebuilds when
/// the tier changes (e.g. when a license activates mid-session).
final Provider<List<CruxSettingsExtraCategory>> extraSettingsSectionsProvider =
    Provider<List<CruxSettingsExtraCategory>>(
      (ref) => const <CruxSettingsExtraCategory>[],
    );
