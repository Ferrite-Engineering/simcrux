// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/inspector/services/editor_launcher.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';

/// The active [EditorLauncher], rebuilt whenever the user's
/// `editorCommandTemplate` setting changes.
final Provider<EditorLauncher> editorLauncherProvider =
    Provider<EditorLauncher>((ref) {
      final asyncSettings = ref.watch(appSettingsProvider);
      final template = asyncSettings.maybeWhen<String>(
        data: (s) => s.editorCommandTemplate,
        orElse: () => 'code --goto {file}:{line}:{column}',
      );
      return EditorLauncher(template: template);
    });
