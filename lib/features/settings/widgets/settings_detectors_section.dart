// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/core/help_urls.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/domain/models/pass_fail_config_codec.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/settings/widgets/detector_editor_dialog.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Settings → Detectors section: lists user-defined reusable
/// pass/fail detectors and provides a "+ Add" / edit / delete UX.
///
/// The visual builder for composite detectors is recursive — a
/// composite's children render the same chip-row + per-kind fields
/// shown at the top level, with `+ Add child` buttons under each
/// AND / OR group. The recursive editor tree lives in
/// [DetectorSpecEditor]; the modal that hosts it is [DetectorEditorDialog].
class SettingsDetectorsSection extends ConsumerWidget {
  /// Creates a [SettingsDetectorsSection].
  const SettingsDetectorsSection({required this.settings, super.key});

  /// Active [AppSettings].
  final AppSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final entries = settings.reusableDetectors.entries.toList(growable: false)
      ..sort((a, b) => a.key.compareTo(b.key));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              l10n.settingsDetectorsEmpty,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          )
        else
          for (final entry in entries)
            _DetectorRow(
              name: entry.key,
              spec: entry.value,
              onEdit: () => _openEditor(
                context,
                ref,
                initialName: entry.key,
                initial: entry.value,
              ),
              onDelete: () => ref
                  .read(appSettingsProvider.notifier)
                  .removeReusableDetector(entry.key),
            ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton.icon(
              icon: const Icon(Icons.add),
              label: Text(l10n.settingsDetectorsAddButton),
              onPressed: () => _openEditor(context, ref),
            ),
            const SizedBox(width: 8),
            // Contextual docs: the pass/fail detection guide (detector
            // kinds, composites, reuse from simcrux.yaml).
            CruxHelpLink(
              url: HelpUrls.passFailDetection,
              tooltip: l10n.helpLinkLearnMore,
            ),
          ],
        ),
      ],
    );
  }

  void _openEditor(
    BuildContext context,
    WidgetRef ref, {
    String? initialName,
    DetectorSpec? initial,
  }) {
    unawaited(
      showDialog<void>(
        context: context,
        // Editor dialogs hold in-progress user input: closing must be a
        // deliberate act (Cancel / Save), never a stray scrim click — the
        // suite dialog canon. Note this
        // also disables Escape (Flutter routes DismissIntent through the
        // barrier flag).
        barrierDismissible: false,
        builder: (_) => DetectorEditorDialog(
          initialName: initialName,
          initial: initial,
          existingNames:
              ref
                  .read(appSettingsProvider)
                  .value
                  ?.reusableDetectors
                  .keys
                  .toSet() ??
              <String>{},
          onCommit: (name, spec) async {
            // If renaming, drop the old entry first.
            if (initialName != null && initialName != name) {
              await ref
                  .read(appSettingsProvider.notifier)
                  .removeReusableDetector(initialName);
            }
            await ref
                .read(appSettingsProvider.notifier)
                .putReusableDetector(name, spec);
          },
        ),
      ),
    );
  }
}

class _DetectorRow extends StatelessWidget {
  const _DetectorRow({
    required this.name,
    required this.spec,
    required this.onEdit,
    required this.onDelete,
  });

  final String name;
  final DetectorSpec spec;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(name, style: Theme.of(context).textTheme.titleSmall),
      subtitle: Text(
        _summarize(spec, l10n),
        style: Theme.of(context).textTheme.bodySmall,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            onPressed: onEdit,
            tooltip: l10n.settingsDetectorEditDialogTitle,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: onDelete,
            tooltip: l10n.settingsDetectorDelete,
          ),
        ],
      ),
    );
  }

  String _summarize(DetectorSpec spec, L10N l10n) {
    switch (spec) {
      case ExitCodeSpec():
        return l10n.settingsDetectorKindExitCode;
      case StringMatchSpec():
        return l10n.settingsDetectorKindStringMatch;
      case RegexSpec():
        return l10n.settingsDetectorKindRegex;
      case UvmReportSpec():
        return l10n.settingsDetectorKindUvmReport;
      case CocotbSpec():
        return l10n.settingsDetectorKindCocotb;
      case GoldenCompareSpec():
        return l10n.settingsDetectorKindGoldenCompare;
      case CompositeSpec(:final allOf, :final anyOf):
        return '${l10n.settingsDetectorKindComposite} '
            '(AND=${allOf.length}, OR=${anyOf.length})';
      case UseSpec(:final name):
        return '${l10n.settingsDetectorKindUse} → $name';
    }
  }
}
