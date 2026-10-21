// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:crux_settings_ui/crux_settings_ui.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/formal_import_result.dart';
import 'package:simcrux/domain/models/sby_script.dart';
import 'package:simcrux/features/dialogs/confirm_dialog.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// What the user asked File > Import Formal Project… to do.
@immutable
class ImportFormalProjectRequest {
  /// Creates a request.
  const ImportFormalProjectRequest({
    required this.sbyPath,
    required this.outputPath,
    this.tasks = const <String>[],
  });

  /// The `.sby` job file.
  final String sbyPath;

  /// Where the project file goes.
  final String outputPath;

  /// The tasks to import; empty imports every task (or the one default
  /// task of a file without `[tasks]`).
  final List<String> tasks;
}

/// Runs an [ImportFormalProjectRequest] and returns a message to show in the
/// dialog when it failed, or null when it succeeded and the dialog closes.
typedef ImportFormalProjectCommit =
    Future<String?> Function(ImportFormalProjectRequest request);

/// The `ModalGuard` key for the dialog: a repeated shortcut or a double
/// click on the menu item opens one copy.
const String kImportFormalProjectGuardKey = 'importFormalProject';

/// Opens File > Import Formal Project….
///
/// A workflow dialog: the barrier is not dismissible (closing is Cancel,
/// Escape or the commit), the open is guarded, and a form with a job file
/// chosen asks before it is discarded. It reads no per-tab provider, so it is
/// window-modal on the root navigator.
Future<void> showImportFormalProjectDialog(
  BuildContext context, {
  required ImportFormalProjectCommit onImport,
  required Future<String?> Function() pickJobFile,
  required Future<String?> Function(String suggestedPath) pickProjectFile,
  required SbyScript Function(String path) readJobFile,
}) {
  return showCruxDialog<void>(
    context: context,
    barrierDismissible: false,
    modalGuardKey: kImportFormalProjectGuardKey,
    builder: (_) => ImportFormalProjectDialog(
      onImport: onImport,
      pickJobFile: pickJobFile,
      pickProjectFile: pickProjectFile,
      readJobFile: readJobFile,
    ),
  );
}

/// The Import Formal Project dialog: a job file, the tasks it declares (all
/// ticked), and the project file to write.
///
/// The pickers and the reader are injected, so the dialog is tested without
/// a platform file chooser and without a disk.
class ImportFormalProjectDialog extends StatefulWidget {
  /// Creates the dialog.
  const ImportFormalProjectDialog({
    required this.onImport,
    required this.pickJobFile,
    required this.pickProjectFile,
    required this.readJobFile,
    super.key,
  });

  /// Runs the import; see [ImportFormalProjectCommit].
  final ImportFormalProjectCommit onImport;

  /// Asks for a `.sby` file; null when the user cancelled.
  final Future<String?> Function() pickJobFile;

  /// Asks where to save, starting from the suggested path; null when the
  /// user cancelled.
  final Future<String?> Function(String suggestedPath) pickProjectFile;

  /// Reads a job file's `[tasks]` (never throws).
  final SbyScript Function(String path) readJobFile;

  @override
  State<ImportFormalProjectDialog> createState() =>
      _ImportFormalProjectDialogState();
}

class _ImportFormalProjectDialogState extends State<ImportFormalProjectDialog> {
  String? _sbyPath;
  SbyScript? _script;
  String? _outputPath;
  final Set<String> _selected = <String>{};
  String? _error;
  bool _busy = false;

  /// A form with a job file chosen holds the user's work.
  bool get _isDirty => _sbyPath != null;

  List<String> get _tasks => _script?.tasks ?? const <String>[];

  bool get _canImport =>
      !_busy &&
      _sbyPath != null &&
      _outputPath != null &&
      (_tasks.isEmpty || _selected.isNotEmpty);

  Future<void> _chooseJobFile() async {
    final path = await widget.pickJobFile();
    if (path == null || !mounted) return;
    final script = widget.readJobFile(path);
    setState(() {
      _sbyPath = path;
      _script = script;
      _selected
        ..clear()
        ..addAll(script.tasks);
      _outputPath ??= p.join(
        p.dirname(path),
        FormalImportResult.kSuggestedOutputFilename,
      );
      _error = null;
    });
  }

  Future<void> _chooseProjectFile() async {
    final suggested =
        _outputPath ??
        p.join(
          p.dirname(_sbyPath ?? ''),
          FormalImportResult.kSuggestedOutputFilename,
        );
    final path = await widget.pickProjectFile(suggested);
    if (path == null || !mounted) return;
    setState(() => _outputPath = path);
  }

  Future<void> _import() async {
    if (!_canImport) return;
    final allTicked = _selected.length == _tasks.length;
    final request = ImportFormalProjectRequest(
      sbyPath: _sbyPath!,
      outputPath: _outputPath!,
      tasks: allTicked
          ? const <String>[]
          : <String>[
              for (final task in _tasks)
                if (_selected.contains(task)) task,
            ],
    );
    setState(() {
      _busy = true;
      _error = null;
    });
    final navigator = Navigator.of(context);
    final failure = await widget.onImport(request);
    if (!mounted) return;
    if (failure == null) {
      navigator.pop();
      return;
    }
    setState(() {
      _busy = false;
      _error = failure;
    });
  }

  Future<void> _onCancel() async {
    if (!_isDirty) {
      Navigator.of(context).pop();
      return;
    }
    final l10n = L10N.of(context);
    final confirmed = await showConfirmDialog(
      context: context,
      title: l10n.importFormalDiscardTitle,
      body: l10n.importFormalDiscardBody,
      cancelLabel: l10n.importFormalDiscardKeep,
      confirmLabel: l10n.importFormalDiscardConfirm,
    );
    if (!confirmed || !mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    final theme = Theme.of(context);
    final tasks = _tasks;
    // Escape closes a Crux dialog through `maybePop`; the pop is handed to
    // the unsaved-changes guard.
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_onCancel());
      },
      child: CruxDialog(
        key: const ValueKey('importFormalProjectDialog'),
        title: l10n.importFormalTitle,
        width: 560,
        onSubmit: _canImport ? () => unawaited(_import()) : null,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.importFormalIntro,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            CruxFormSection(
              children: [
                CruxFormRow(
                  label: l10n.importFormalJobFileLabel,
                  child: _PathChooser(
                    path: _sbyPath,
                    emptyText: l10n.importFormalJobFileNone,
                    buttonKey: const ValueKey('importFormalChooseJobFile'),
                    buttonLabel: l10n.importFormalChoose,
                    onPressed: _busy ? null : () => unawaited(_chooseJobFile()),
                  ),
                ),
                CruxFormRow(
                  label: l10n.importFormalProjectFileLabel,
                  child: _PathChooser(
                    path: _outputPath,
                    emptyText: l10n.importFormalProjectFileNone,
                    buttonKey: const ValueKey('importFormalChooseProjectFile'),
                    buttonLabel: l10n.importFormalChoose,
                    onPressed: _busy || _sbyPath == null
                        ? null
                        : () => unawaited(_chooseProjectFile()),
                  ),
                ),
              ],
            ),
            if (_script != null) ...[
              const SizedBox(height: 12),
              CruxFormSection(
                title: l10n.importFormalTasksHeading,
                children: [
                  if (tasks.isEmpty)
                    Text(
                      l10n.importFormalNoTasks,
                      style: theme.textTheme.bodySmall,
                    )
                  else
                    for (final task in tasks)
                      CruxFormRow.checkbox(
                        key: ValueKey('importFormalTask-$task'),
                        label: task,
                        value: _selected.contains(task),
                        onChanged: _busy
                            ? null
                            : (on) => setState(() {
                                if (on) {
                                  _selected.add(task);
                                } else {
                                  _selected.remove(task);
                                }
                              }),
                      ),
                ],
              ),
            ],
            if (_error case final String error) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  error,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          CruxDialogAction(
            key: const ValueKey('importFormalCancel'),
            label: l10n.importFormalCancel,
            onPressed: () => unawaited(_onCancel()),
          ),
          CruxDialogAction(
            key: const ValueKey('importFormalImport'),
            label: l10n.importFormalImport,
            role: CruxDialogActionRole.primary,
            onPressed: _canImport ? () => unawaited(_import()) : null,
          ),
        ],
      ),
    );
  }
}

/// A path shown as text with a Choose… button after it. The button is the
/// row's one focus stop, so the row label, the path and the button are one
/// announcement.
class _PathChooser extends StatelessWidget {
  const _PathChooser({
    required this.path,
    required this.emptyText,
    required this.buttonKey,
    required this.buttonLabel,
    required this.onPressed,
  });

  final String? path;
  final String emptyText;
  final Key buttonKey;
  final String buttonLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = path;
    return Row(
      children: [
        Expanded(
          child: Text(
            shown ?? emptyText,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: shown == null ? theme.colorScheme.onSurfaceVariant : null,
            ),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          key: buttonKey,
          onPressed: onPressed,
          child: Text(buttonLabel),
        ),
      ],
    );
  }
}
