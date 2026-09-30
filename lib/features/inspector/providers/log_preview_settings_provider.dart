// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';

/// Default tail-line count shown in the inspector's log preview when
/// the user hasn't customized it in Settings.
const int kDefaultInspectorLogPreviewLineCount = 50;

/// Minimum / maximum sliders on the Settings → General "Log preview
/// lines" knob. Below 10 lines the preview is uselessly short; above
/// 500 it starts to dominate the inspector and slows the build.
const int kMinInspectorLogPreviewLineCount = 10;
const int kMaxInspectorLogPreviewLineCount = 500;

/// How many trailing log lines to show in the inspector. Sourced from
/// [AppSettings]; falls back to the documented default while settings
/// are loading or failed to load.
final Provider<int> logPreviewLineCountProvider = Provider<int>(
  (ref) {
    final asyncSettings = ref.watch(appSettingsProvider);
    return asyncSettings.maybeWhen<int>(
      data: (settings) => settings.inspectorLogPreviewLineCount,
      orElse: () => kDefaultInspectorLogPreviewLineCount,
    );
  },
);
