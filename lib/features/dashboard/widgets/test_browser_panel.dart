// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/core/theme/simcrux_colors.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_status_icon.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Left-pane test browser.
///
/// Renders the active project's suite/test hierarchy as a collapsible
/// list. Each test row shows a status icon derived from the active
/// run's [DashboardRow] (when the test has run) and the test name.
/// Tapping a row sets [selectedTestIdProvider] — same provider the
/// dashboard table row tap drives — so the right-side inspector
/// updates to the same selection.
///
/// Empty state (config not loaded) renders the
/// [L10N.panelTestBrowserPlaceholder] copy.
///
/// **Not implemented:**
/// - A "Recent runs" strip (last N regression runs as colored squares)
///   showing the project-level run history.
/// - Per-suite filter / search.
/// - Drag-to-rearrange or favorites.
class TestBrowserPanel extends ConsumerWidget {
  /// Creates a [TestBrowserPanel].
  const TestBrowserPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final theme = Theme.of(context);

    final config = ref.watch(activeConfigProvider);
    if (config == null) {
      return Container(
        color: theme.colorScheme.surface,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(24),
        child: Text(
          l10n.panelTestBrowserPlaceholder,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    // Index dashboard rows by testId so per-test status lookups are
    // O(1). The dashboard table populates this stream on every test
    // result, so the browser status icons stay in sync with the table.
    final rowsAsync = ref.watch(dashboardRowsProvider);
    final rowsById = <String, DashboardRow>{};
    rowsAsync.maybeWhen(
      data: (rows) {
        for (final row in rows) {
          rowsById[row.testId] = row;
        }
      },
      orElse: () {},
    );

    final selectedTestId = ref.watch(selectedTestIdProvider);

    return Material(
      color: theme.colorScheme.surface,
      child: ListView.builder(
        itemCount: config.suites.length,
        itemBuilder: (context, suiteIndex) {
          final suite = config.suites[suiteIndex];
          return _SuiteSection(
            suiteName: suite.name,
            testIds: [for (final t in suite.tests) t.id],
            testNames: [for (final t in suite.tests) t.name],
            rowsById: rowsById,
            selectedTestId: selectedTestId,
            onTestTap: (testId) =>
                ref.read(selectedTestIdProvider.notifier).select(testId),
          );
        },
      ),
    );
  }
}

class _SuiteSection extends StatefulWidget {
  const _SuiteSection({
    required this.suiteName,
    required this.testIds,
    required this.testNames,
    required this.rowsById,
    required this.selectedTestId,
    required this.onTestTap,
  });

  final String suiteName;
  final List<String> testIds;
  final List<String> testNames;
  final Map<String, DashboardRow> rowsById;
  final String? selectedTestId;
  final void Function(String testId) onTestTap;

  @override
  State<_SuiteSection> createState() => _SuiteSectionState();
}

class _SuiteSectionState extends State<_SuiteSection> {
  /// Mirrors the tile's own state, which it does not expose, so the header
  /// can say whether it is open.
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpansionTile(
      initiallyExpanded: true,
      onExpansionChanged: (expanded) => setState(() => _expanded = expanded),
      // A button with an expanded or collapsed state. The tile on its own is
      // announced as plain "uart text" on desktop: its expand and collapse
      // wording is a semantics hint, which the desktop bridges drop. These
      // flags merge into the header's node, the one Tab reaches.
      title: Semantics(
        button: true,
        expanded: _expanded,
        child: Text(
          widget.suiteName,
          style: theme.textTheme.titleSmall,
        ),
      ),
      children: [
        for (var i = 0; i < widget.testIds.length; i++)
          _TestRow(
            testId: widget.testIds[i],
            testName: widget.testNames[i],
            row: widget.rowsById[widget.testIds[i]],
            selected: widget.selectedTestId == widget.testIds[i],
            onTap: () => widget.onTestTap(widget.testIds[i]),
          ),
      ],
    );
  }
}

class _TestRow extends StatelessWidget {
  const _TestRow({
    required this.testId,
    required this.testName,
    required this.row,
    required this.selected,
    required this.onTap,
  });

  final String testId;
  final String testName;
  final DashboardRow? row;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10N.of(context);
    final status = row?.result.status;
    return ListTile(
      dense: true,
      selected: selected,
      onTap: onTap,
      leading: _StatusIcon(status: status),
      // The status is drawn only as a colored icon, which announces nothing,
      // so the name carries it: "tx_basic, Fail".
      title: Semantics(
        label: l10n.accessibilityTestBrowserRow(
          testName,
          status == null
              ? l10n.accessibilityTestNotRun
              : testStatusLabel(l10n, status),
        ),
        child: ExcludeSemantics(
          child: Text(
            testName,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ),
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status});

  final TestStatus? status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = this.status;
    final icon = switch (status) {
      TestStatus.pass => Icons.check_circle,
      TestStatus.fail => Icons.cancel,
      TestStatus.timeout => Icons.timer_off,
      TestStatus.skipped => Icons.remove_circle_outline,
      TestStatus.cancelled => Icons.block,
      TestStatus.vacuous => Icons.info_outline,
      TestStatus.cover => Icons.flag,
      TestStatus.running => Icons.play_circle_outline,
      TestStatus.unknown => Icons.help_outline,
      null => Icons.circle_outlined,
    };
    // The color is the one shared per-status token (see
    // SimcruxColors.statusColor); the "no result yet" (null) case has no
    // status to color and falls back to a faint neutral.
    final color = status == null
        ? theme.colorScheme.outlineVariant
        : SimcruxColors.statusColor(status, theme.colorScheme);
    return Icon(icon, size: 18, color: color);
  }
}
