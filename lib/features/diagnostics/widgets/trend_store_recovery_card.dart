// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/models/trend_store_rebuild_report.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/trend_store/trend_store_corruption_provider.dart';
import 'package:simcrux/services/trend_store/trend_store_provider.dart';
import 'package:simcrux/services/trend_store/trend_store_rebuild.dart';

/// The App Diagnostics dialog's trend-database recovery card.
///
/// Renders nothing in the healthy case, which is every case until a
/// `trends.db` fails to open. When one has, this is the only place in SimCrux
/// that says so — the quarantine is otherwise invisible, because
/// `CruxDbRecovery.renameAside` opens a fresh, empty database in the damaged
/// file's place and an empty trend chart looks exactly like a project that has
/// never been run.
///
/// It offers the user up to two ways back, and is careful about which it
/// recommends:
///
///  * **The pre-upgrade backup**, when one exists. A `VACUUM INTO` snapshot
///    taken before the last schema change is a complete database. It is the
///    better recovery whenever it is on disk, and it is named by absolute path
///    so the user can copy it into place themselves — SimCrux does not do that
///    for them, because moving a database over another database is not a thing
///    an app should do behind a dialog.
///  * **A rebuild from `results.ndjson`**, always. Explicit, never automatic,
///    and stated honestly: it recovers the runs whose streaming archives the
///    user still has, and nothing else. A rebuild that quietly produced a
///    partial history looking like a complete one would be a worse bug than
///    the corruption it recovered from.
class TrendStoreRecoveryCard extends ConsumerStatefulWidget {
  /// Creates a [TrendStoreRecoveryCard].
  const TrendStoreRecoveryCard({super.key});

  @override
  ConsumerState<TrendStoreRecoveryCard> createState() =>
      _TrendStoreRecoveryCardState();
}

class _TrendStoreRecoveryCardState
    extends ConsumerState<TrendStoreRecoveryCard> {
  bool _rebuilding = false;
  TrendStoreRebuildReport? _report;
  String? _failure;

  @override
  Widget build(BuildContext context) {
    final notice = ref.watch(trendStoreCorruptionProvider);
    if (notice == null) return const SizedBox.shrink();
    final l10n = L10N.of(context);
    final theme = Theme.of(context);
    final onError = theme.colorScheme.onErrorContainer;
    final quarantined = notice.quarantinedPath;
    final backup = notice.backupPath;

    return Material(
      color: theme.colorScheme.errorContainer,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_outlined, color: onError),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    l10n.diagnosticsTrendRecoveryTitle,
                    style: theme.textTheme.titleSmall?.copyWith(color: onError),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText(
              quarantined != null
                  ? l10n.diagnosticsTrendRecoveryQuarantined(
                      notice.path,
                      quarantined,
                    )
                  : l10n.diagnosticsTrendRecoveryUnmoved(notice.path),
              style: theme.textTheme.bodySmall?.copyWith(color: onError),
            ),
            if (backup != null) ...[
              const SizedBox(height: 8),
              SelectableText(
                l10n.diagnosticsTrendRecoveryBackup(backup),
                style: theme.textTheme.bodySmall?.copyWith(color: onError),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              l10n.diagnosticsTrendRecoveryRebuildExplainer,
              style: theme.textTheme.bodySmall?.copyWith(color: onError),
            ),
            if (_report case final report?) ...[
              const SizedBox(height: 8),
              Text(
                _summaryOf(report, l10n),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: onError,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
            if (_failure case final failure?) ...[
              const SizedBox(height: 8),
              Text(
                l10n.diagnosticsTrendRecoveryRebuildFailed(failure),
                style: theme.textTheme.bodySmall?.copyWith(color: onError),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _rebuilding ? null : _pickAndRebuild,
                  icon: _rebuilding
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.restore_page_outlined),
                  label: Text(
                    _rebuilding
                        ? l10n.diagnosticsTrendRecoveryRebuilding
                        : l10n.diagnosticsTrendRecoveryRebuildAction,
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _rebuilding
                      ? null
                      : () => ref
                            .read(trendStoreCorruptionProvider.notifier)
                            .dismiss(),
                  child: Text(l10n.diagnosticsTrendRecoveryDismiss),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Localized arithmetic, not reassurance: how much came back, and how many
  /// of the chosen archives gave nothing.
  String _summaryOf(TrendStoreRebuildReport report, L10N l10n) {
    if (report.isEmpty) {
      return l10n.diagnosticsTrendRecoveryRebuildNothing(
        report.archives.length,
      );
    }
    final recovered = l10n.diagnosticsTrendRecoveryRebuildResult(
      report.pointsRecovered,
      report.runsRecovered,
    );
    if (report.archivesSkipped == 0) return recovered;
    return '$recovered '
        '${l10n.diagnosticsTrendRecoverySkipped(report.archivesSkipped)}';
  }

  Future<void> _pickAndRebuild() async {
    final l10n = L10N.of(context);
    final FilePickerResult? picked;
    try {
      // Multi-select is the default and the point: a rebuild is only as good
      // as the number of archives the user can hand it at once.
      picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['ndjson'],
        dialogTitle: l10n.diagnosticsTrendRecoveryPickerTitle,
      );
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _failure = '$error');
      return;
    }
    if (picked == null) return;
    final paths = <String>[for (final file in picked.files) ?file.path];
    if (paths.isEmpty || !mounted) return;
    // The container, not `ref`, past the rebuild's awaits: a rebuild runs as
    // long as its archives take and can outlive this card, and the storage
    // figures it changes must be re-read even if the card is gone by then.
    final container = ProviderScope.containerOf(context, listen: false);

    setState(() {
      _rebuilding = true;
      _failure = null;
      _report = null;
    });
    try {
      final store = await container.read(trendStoreProvider.future);
      final report = await const TrendStoreRebuilder().rebuild(
        store: store,
        archivePaths: paths,
      );
      // The dialog's own storage line is computed from a provider that has
      // already resolved; without this the user reads "0 data points"
      // directly under a message saying how many just came back.
      container.invalidate(trendStorageStatsProvider);
      if (!mounted) return;
      setState(() {
        _rebuilding = false;
        _report = report;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _rebuilding = false;
        _failure = '$error';
      });
    }
  }
}
