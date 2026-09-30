// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';

/// Gating provider for every diagnostics surface (Tab Diagnostics
/// drawer, App Diagnostics dialog, Pane Render Stats popover).
///
/// In debug/profile builds the diagnostics surfaces are unconditionally
/// available; in release builds the user must opt in via
/// `CoreSettings.diagnosticsEnabled`.
final Provider<bool> diagnosticsEnabledProvider = Provider<bool>((ref) {
  if (kDebugMode || kProfileMode) return true;
  final settings = ref.watch(appSettingsProvider);
  return settings.maybeWhen<bool>(
    data: (s) => s.diagnosticsEnabled,
    orElse: () => false,
  );
});
