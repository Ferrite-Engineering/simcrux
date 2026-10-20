// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:crux_settings_ui/crux_settings_ui.dart';
import 'package:flutter/material.dart';
import 'package:simcrux/domain/models/pass_fail_config_codec.dart';
import 'package:simcrux/features/dialogs/confirm_dialog.dart';
import 'package:simcrux/features/settings/widgets/detector_spec_editor.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Modal dialog that edits a [DetectorSpec] tree.
class DetectorEditorDialog extends StatefulWidget {
  /// Creates a [DetectorEditorDialog].
  const DetectorEditorDialog({
    required this.onCommit,
    required this.existingNames,
    this.initialName,
    this.initial,
    super.key,
  });

  /// Name to seed when editing an existing detector.
  final String? initialName;

  /// Spec to seed when editing.
  final DetectorSpec? initial;

  /// Names that already exist — surfaced in the `use` picker so the
  /// user can reference a sibling detector. Includes [initialName].
  final Set<String> existingNames;

  /// Called with the resolved `(name, spec)` when the user saves.
  final Future<void> Function(String name, DetectorSpec spec) onCommit;

  @override
  State<DetectorEditorDialog> createState() => _DetectorEditorDialogState();
}

class _DetectorEditorDialogState extends State<DetectorEditorDialog> {
  late final TextEditingController _nameController;
  late DetectorSpec _root;
  late final String _initialName;
  late final DetectorSpec _initialRoot;
  bool _nameMissing = false;

  @override
  void initState() {
    super.initState();
    _initialName = widget.initialName ?? '';
    _nameController = TextEditingController(text: _initialName);
    _initialRoot = widget.initial ?? const ExitCodeSpec();
    _root = _initialRoot;
  }

  /// Whether the form differs from the values it opened with — the spec
  /// subtypes implement value equality, so a round-trip edit back to
  /// the original counts as clean. Clean forms close without a prompt;
  /// dirty ones confirm first (suite unsaved-changes canon).
  bool get _isDirty =>
      _nameController.text != _initialName || _root != _initialRoot;

  Future<void> _onCancel() async {
    if (!_isDirty) {
      Navigator.of(context).pop();
      return;
    }
    final l10n = L10N.of(context);
    final confirmed = await showConfirmDialog(
      context: context,
      title: l10n.settingsDetectorDiscardConfirmTitle,
      body: l10n.settingsDetectorDiscardConfirmBody,
      cancelLabel: l10n.settingsDetectorDiscardConfirmNo,
      confirmLabel: l10n.settingsDetectorDiscardConfirmYes,
    );
    if (!confirmed || !mounted) return;
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    // Escape closes a Crux dialog through `maybePop`, so the unsaved-changes
    // guard runs for it too: the pop is always handed to `_onCancel`.
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_onCancel());
      },
      child: CruxDialog(
        title: l10n.settingsDetectorEditDialogTitle,
        width: 580,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            CruxFormSection(
              children: [
                CruxFormRow(
                  label: l10n.settingsDetectorNameLabel,
                  child: TextField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      hintText: l10n.settingsDetectorNameHint,
                      errorText: _nameMissing
                          ? l10n.settingsDetectorNameRequired
                          : null,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            DetectorSpecEditor(
              spec: _root,
              existingNames: widget.existingNames
                  .where((n) => n != widget.initialName)
                  .toSet(),
              onChanged: (next) => setState(() => _root = next),
            ),
          ],
        ),
        actions: [
          CruxDialogAction(
            label: l10n.settingsDetectorCancel,
            onPressed: _onCancel,
          ),
          CruxDialogAction(
            label: l10n.settingsDetectorSave,
            role: CruxDialogActionRole.primary,
            onPressed: () async {
              final name = _nameController.text.trim();
              if (name.isEmpty) {
                setState(() => _nameMissing = true);
                return;
              }
              final navigator = Navigator.of(context);
              await widget.onCommit(name, _root);
              if (!mounted) return;
              navigator.pop();
            },
          ),
        ],
      ),
    );
  }
}
