// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Editor command template presets — VS Code / Sublime / Vim / Emacs
/// / Custom — that source-navigation actions shell out to.
class SettingsEditorSection extends ConsumerStatefulWidget {
  /// Creates a [SettingsEditorSection].
  const SettingsEditorSection({required this.settings, super.key});

  /// Currently-loaded [AppSettings].
  final AppSettings settings;

  @override
  ConsumerState<SettingsEditorSection> createState() =>
      _SettingsEditorSectionState();
}

class _SettingsEditorSectionState extends ConsumerState<SettingsEditorSection> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.settings.editorCommandTemplate,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _applyTemplate(String template) {
    _controller.text = template;
    unawaited(
      ref
          .read(appSettingsProvider.notifier)
          .updateEditorCommandTemplate(template),
    );
  }

  static const _presets = <(String Function(L10N), String)>[
    (_vscodeLabel, 'code --goto {file}:{line}:{column}'),
    (_sublimeLabel, 'subl {file}:{line}'),
    (_vimLabel, 'vim +{line} {file}'),
    (_emacsLabel, 'emacsclient -n +{line}:{column} {file}'),
  ];

  static String _vscodeLabel(L10N l) => l.settingsEditorPresetVscode;
  static String _sublimeLabel(L10N l) => l.settingsEditorPresetSublime;
  static String _vimLabel(L10N l) => l.settingsEditorPresetVim;
  static String _emacsLabel(L10N l) => l.settingsEditorPresetEmacs;

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          children: [
            for (final preset in _presets)
              ChoiceChip(
                label: Text(preset.$1(l10n)),
                selected: _controller.text == preset.$2,
                onSelected: (_) => _applyTemplate(preset.$2),
              ),
            ChoiceChip(
              label: Text(l10n.settingsEditorPresetCustom),
              selected: _presets.every((p) => _controller.text != p.$2),
              onSelected: (_) {},
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _controller,
          decoration: InputDecoration(
            isDense: true,
            labelText: l10n.settingsEditorCommandLabel,
            helperText: l10n.settingsEditorCommandHelp,
            helperMaxLines: 3,
          ),
          onSubmitted: (value) {
            unawaited(
              ref
                  .read(appSettingsProvider.notifier)
                  .updateEditorCommandTemplate(value),
            );
          },
        ),
        const SizedBox(height: 4),
        Text(
          _controller.text,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }
}
