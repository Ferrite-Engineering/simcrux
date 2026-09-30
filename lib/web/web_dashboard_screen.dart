// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/web/web_filter.dart';
import 'package:simcrux/web/web_inspector_dialog.dart';
import 'package:simcrux/web/web_results_document.dart';
import 'package:simcrux/web/web_results_provider.dart';
import 'package:simcrux/web/web_status_chip.dart';

/// Picks a local results file and publishes it to
/// [webOpenedDocumentProvider].
///
/// The web viewer otherwise only loads results from a `?results=<url>`
/// query parameter or an auto-fetched same-origin document, so a user
/// with a local `.ndjson` / `.json` had no in-UI way to load it. This
/// mirrors LintCrux's web "Open SARIF File…" upload: `withData: true`
/// returns the bytes in-memory (no filesystem path on web), which decode
/// through [WebResultsDocument.decode] (auto-detecting the consolidated
/// JSON vs. NDJSON shape). Parse / read failures surface as a SnackBar
/// rather than replacing the currently-shown results.
Future<void> openWebResultsFile(BuildContext context, WidgetRef ref) async {
  final l10n = L10N.of(context);
  FilePickerResult? result;
  try {
    result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['ndjson', 'json'],
    );
  } on Object catch (e) {
    if (!context.mounted) return;
    showCruxErrorSnack(context, l10n.webDashboardOpenFileFailed('$e'));
    return;
  }
  if (result == null || result.files.isEmpty) return;
  try {
    // `readAsBytes()` returns the file contents in-memory on every
    // platform (on web there is no filesystem path to stream from).
    final bytes = await result.files.single.readAsBytes();
    final doc = WebResultsDocument.decode(utf8.decode(bytes));
    ref.read(webOpenedDocumentProvider.notifier).set(doc);
  } on Object catch (e) {
    if (!context.mounted) return;
    showCruxErrorSnack(context, l10n.webDashboardOpenFileFailed('$e'));
  }
}

/// Top-level screen for the read-only web build.
class WebDashboardScreen extends ConsumerWidget {
  /// Creates a [WebDashboardScreen].
  const WebDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    // A user-opened file takes precedence over the auto-fetched
    // `?results=` / same-origin document.
    final opened = ref.watch(webOpenedDocumentProvider);
    final asyncDoc = ref.watch(webResultsProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.webDashboardTitle),
        actions: <Widget>[
          // Always reachable: open a local results file from any state
          // (loading, error, or an already-loaded document).
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton.icon(
              onPressed: () => unawaited(openWebResultsFile(context, ref)),
              icon: const Icon(Icons.upload_file),
              label: Text(l10n.webDashboardOpenFileButton),
            ),
          ),
        ],
      ),
      body: opened != null
          ? _WebDashboardBody(opened)
          : asyncDoc.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, _) => _LoadFailed(error: '$err'),
              data: _WebDashboardBody.new,
            ),
    );
  }
}

/// Body shown when the auto-fetch failed: the reason plus a prominent
/// "Open results file…" button so a user who has a local file — but no
/// hosted `?results=` URL or bundled document — is not stuck.
class _LoadFailed extends ConsumerWidget {
  const _LoadFailed({required this.error});

  final String error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.inbox_outlined,
                size: 56,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 16),
              Text(
                l10n.webDashboardLoadFailed(error),
                style: theme.textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () => unawaited(openWebResultsFile(context, ref)),
                icon: const Icon(Icons.upload_file),
                label: Text(l10n.webDashboardOpenFileButton),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WebDashboardBody extends ConsumerWidget {
  const _WebDashboardBody(this.doc);

  final WebResultsDocument doc;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final filter = ref.watch(webFilterProvider);
    final rows = filter.apply(doc.rows);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ReadOnlyBanner(text: l10n.webDashboardReadOnlyBanner),
        _FilterBar(filter: filter),
        Expanded(
          child: doc.rows.isEmpty
              ? _EmptyState(
                  title: l10n.webDashboardEmptyTitle,
                  body: l10n.webDashboardEmptyBody,
                )
              : _ResultsTable(rows: rows),
        ),
        _StatusBar(totals: doc.totals, total: doc.rows.length),
      ],
    );
  }
}

class _ReadOnlyBanner extends StatelessWidget {
  const _ReadOnlyBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          Icon(
            Icons.lock_outline,
            size: 14,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterBar extends ConsumerStatefulWidget {
  const _FilterBar({required this.filter});

  final WebFilter filter;

  @override
  ConsumerState<_FilterBar> createState() => _FilterBarState();
}

class _FilterBarState extends ConsumerState<_FilterBar> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.filter.query);
  }

  @override
  void didUpdateWidget(covariant _FilterBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.filter.query != _controller.text) {
      _controller.text = widget.filter.query;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  decoration: InputDecoration(
                    hintText: l10n.webDashboardSearchHint,
                    prefixIcon: const Icon(Icons.search),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (text) =>
                      ref.read(webFilterProvider.notifier).setQuery(text),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: widget.filter.isEmpty
                    ? null
                    : () {
                        _controller.clear();
                        ref.read(webFilterProvider.notifier).clear();
                      },
                child: Text(l10n.webDashboardClearFilter),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final status in const [
                TestStatus.pass,
                TestStatus.fail,
                TestStatus.timeout,
                TestStatus.skipped,
                TestStatus.unknown,
              ])
                FilterChip(
                  label: Text(status.name),
                  selected: widget.filter.statuses.contains(status),
                  onSelected: (_) =>
                      ref.read(webFilterProvider.notifier).toggleStatus(status),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ResultsTable extends ConsumerWidget {
  const _ResultsTable({required this.rows});

  final List<WebResultRow> rows;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final row = rows[i];
        return InkWell(
          onTap: () {
            ref.read(webSelectedTestProvider.notifier).select(row.testId);
            unawaited(
              showDialog<void>(
                context: context,
                builder: (_) => WebInspectorDialog(row: row),
              ),
            );
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: theme.dividerColor, width: 0.5),
              ),
            ),
            child: Row(
              children: [
                SizedBox(width: 76, child: WebStatusChip(row.status)),
                Expanded(
                  flex: 3,
                  child: Text(
                    row.testId,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    row.suiteName,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    row.simulatorId,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                SizedBox(
                  width: 90,
                  child: Text(
                    _formatDuration(row.runtime),
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatDuration(Duration d) {
    if (d.inMilliseconds < 1000) {
      return '${d.inMilliseconds} ms';
    }
    final seconds = d.inMilliseconds / 1000.0;
    if (seconds < 60) {
      return '${seconds.toStringAsFixed(1)} s';
    }
    final minutes = seconds ~/ 60;
    final rem = (seconds - minutes * 60).toStringAsFixed(0);
    return '${minutes}m ${rem}s';
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.totals, required this.total});

  final Map<TestStatus, int> totals;
  final int total;

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Text(
        l10n.webDashboardStatusSummary(
          total,
          totals[TestStatus.pass] ?? 0,
          totals[TestStatus.fail] ?? 0,
          totals[TestStatus.timeout] ?? 0,
          totals[TestStatus.skipped] ?? 0,
        ),
        style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.inbox_outlined,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              body,
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
