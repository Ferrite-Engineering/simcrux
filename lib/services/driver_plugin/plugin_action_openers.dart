// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Opener callback for a plugin-SDK action surface. Receives the
/// [BuildContext] anchored at the invocation site so the Pro overlay
/// can decide whether to push a route, mount a modal dialog, or show
/// a snackbar.
typedef PluginActionOpener = void Function(BuildContext context);

/// Extension-point seam for the Pro Settings → Plugins panel.
///
/// **Open-core default.** Returns `null` — the plugin manager is a
/// Pro feature; the menu / command palette entry remains visible so
/// users discover the capability, but firing it surfaces the
/// Pro-gated snackbar until the Pro overlay registers the opener.
///
/// **Pro override.** The Pro overlay's `proOverrides` list replaces
/// this provider with a callback that opens the Settings dialog on
/// the Plugins section (tier-gated via `proFeatureUnlocked`).
final Provider<PluginActionOpener?> pluginManagerOpenerProvider =
    Provider<PluginActionOpener?>((ref) => null);

/// Extension-point seam for the `reloadPlugins` action.
///
/// **Open-core default.** Returns `null` — plugin loading is a Pro
/// feature (open-core ships only `NoopSimulatorDriverPluginRegistry`),
/// so the action surfaces the Pro-gated snackbar until the Pro
/// overlay registers the opener.
///
/// **Pro override.** Re-scans the configured plugin directory by
/// invalidating `installedPluginsProvider` and reports the resulting
/// installed count (or, when the user has not yet granted the
/// plugin-safety acknowledgment, points them at Settings → Plugins).
final Provider<PluginActionOpener?> reloadPluginsOpenerProvider =
    Provider<PluginActionOpener?>((ref) => null);
