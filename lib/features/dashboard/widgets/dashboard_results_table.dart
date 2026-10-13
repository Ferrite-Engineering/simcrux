// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:crux_table/crux_table.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/features/dashboard/models/dashboard_sort.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_column_layout_provider.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_row_extensions.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_status_icon.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Column widths (logical pixels) used by both the header row and
/// each body row so the columns line up. The checkbox column is fixed; the
/// others share the rest by the weights in [dashboardColumnLayoutProvider],
/// which the header's dividers drag. Header and row height is crux_table's
/// [kCruxTableRowHeight], the suite's table density.
const double _kCheckboxColumnWidth = 32;

/// The id under which crux_table keys the header cells and dividers:
/// `dashboardHeader-<column>` and `dashboardResize-<column>`.
const String _kTableId = 'dashboard';

/// The status glyph's size in a [kCruxTableRowHeight] row.
const double _kStatusIconSize = 16;

/// Narrowest width the table lays its columns out at; below this it scrolls
/// horizontally instead of squeezing further.
///
/// The check box takes 32 px, leaving 648 for the resizable columns —
/// about 60 px per default weight unit, which is the point where
/// "Simulator" still reads as a word. Without a floor the proportional
/// columns kept shrinking with the pane until the headers were single
/// letters and the sort arrow, being a fixed 18 px, overflowed its cell.
const double _kMinTableWidth = 680;

/// The dashboard's centerpiece results table.
///
/// Virtualized `ListView.builder` so a 10,000-row regression stays
/// scroll-smooth; results stream into the table as soon as
/// [dashboardRowsProvider] emits them. Column headers are clickable
/// to flip the active sort, and the divider on a header's right edge drags
/// that column's width against its neighbour (double-click restores the
/// defaults); the leftmost checkbox column lets the user multi-select rows
/// (bulk actions land in a follow-on batch).
class DashboardResultsTable extends ConsumerWidget {
  /// Creates a [DashboardResultsTable].
  const DashboardResultsTable({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final rowsAsync = ref.watch(dashboardRowsProvider);
    final table = Column(
      children: [
        const _DashboardHeaderRow(),
        Expanded(
          child: rowsAsync.when(
            loading: () => Center(child: Text(l10n.dashboardLoading)),
            error: (_, _) => Center(child: Text(l10n.dashboardError)),
            data: (rows) {
              if (rows.isEmpty) {
                return Center(child: Text(l10n.dashboardEmpty));
              }
              return ListView.builder(
                itemCount: rows.length,
                itemExtent: kCruxTableRowHeight,
                itemBuilder: (context, index) {
                  return _DashboardResultRow(row: rows[index]);
                },
              );
            },
          ),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= _kMinTableWidth) return table;
        // One scroll view around header AND rows, so the columns stay
        // aligned while scrolled — two scrollables would drift apart.
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(width: _kMinTableWidth, child: table),
        );
      },
    );
  }
}

/// The header: crux_table's, with a sortable cell per column and a drag
/// divider between neighbours (double-click restores the default widths).
/// The dividers are pointer-only and out of semantics, so the table's
/// keyboard order and what a screen reader announces are unchanged.
class _DashboardHeaderRow extends ConsumerWidget {
  const _DashboardHeaderRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final layout = ref.watch(dashboardColumnLayoutProvider);
    final sort = ref.watch(dashboardSortProvider);
    final labels = <DashboardSortColumn, String>{
      DashboardSortColumn.status: l10n.dashboardColumnStatus,
      DashboardSortColumn.suite: l10n.dashboardColumnSuite,
      DashboardSortColumn.testName: l10n.dashboardColumnTest,
      DashboardSortColumn.simulator: l10n.dashboardColumnSimulator,
      DashboardSortColumn.duration: l10n.dashboardColumnDuration,
      DashboardSortColumn.startedAt: l10n.dashboardColumnStartedAt,
    };
    return CruxTableHeader<DashboardSortColumn>(
      tableId: _kTableId,
      layout: layout,
      controller: ref.read(dashboardColumnLayoutProvider.notifier),
      leading: const [SizedBox(width: _kCheckboxColumnWidth)],
      // A button, not "text": the header sorts when activated, and a screen
      // reader only says so when the node carries the button role. Only the
      // sorted column carries the arrow, so the others keep its 18 px for
      // their label.
      cellBuilder: (context, column) => CruxSortableHeaderCell(
        key: cruxTableHeaderKey(_kTableId, column),
        label: labels[column]!,
        sorted: sort.column == column,
        ascending: sort.direction == DashboardSortDirection.ascending,
        onTap: () =>
            ref.read(dashboardSortProvider.notifier).toggleColumn(column),
      ),
    );
  }
}

class _DashboardResultRow extends ConsumerWidget {
  const _DashboardResultRow({required this.row});

  final DashboardRow row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final layout = ref.watch(dashboardColumnLayoutProvider);
    final selection = ref.watch(dashboardSelectionProvider);
    final selected = selection.contains(row.testId);
    final focused = ref.watch(selectedTestIdProvider) == row.testId;
    final bg = focused
        ? theme.colorScheme.primaryContainer.withValues(alpha: 0.6)
        : selected
        ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
        : null;

    // Optional annotation produced by the Pro-overlay-overridable
    // [dashboardRowTrailingBuilderProvider] (the flaky-classification
    // chip). It marks the test, so it sits in the Test cell after the name
    // rather than in a reserved column at the row's end: a fixed slot there
    // stopped the last column short of the pane edge. Open-core default
    // returns null.
    final trailingBuilder = ref.watch(dashboardRowTrailingBuilderProvider);
    final trailing = trailingBuilder(ref, row);

    // Optional per-row context menu, produced by the Pro-overlay-
    // overridable [dashboardRowContextMenuBuilderProvider]. Open-core
    // default returns an empty list — right-click / long-press are
    // inert. Pro registers a "Cross-probe to peer →" submenu via
    // proOverrides.
    final contextMenuBuilder = ref.watch(
      dashboardRowContextMenuBuilderProvider,
    );

    // ONE announcement per row, not five.
    //
    // The cells below are separate Text widgets, so a screen reader reads
    // five disconnected fragments with no column context — "uart",
    // "tx_basic", "verilator", "1.2 s", "14:03". Each is labelled and the row
    // is unusable. The status comes from the shared `testStatusLabel` rather
    // than the icon, whose tooltip is the bare status word.
    //
    // The sentence is the name of the row's check box, because the check box
    // is the row's one keyboard focus stop. A row gesture in the semantics
    // tree is a second tap action beside the check box's, which stops Flutter
    // merging the two: a screen reader then hears the row as a grouping named
    // "Pass Pass: uart / …", with the icon's tooltip as a second name,
    // followed by a bare "check box not checked". So the row gesture is
    // pointer-only, out of semantics and focus, and the keyboard reaches both
    // actions from the check box: Space toggles it, Enter opens the test in
    // the inspector — what a click on the row does.
    //
    // The visible cells are unchanged: this alters what is heard, not what is
    // drawn.
    final spoken = L10N
        .of(context)
        .accessibilityResultRow(
          testStatusLabel(L10N.of(context), row.result.status),
          row.suiteName,
          row.testName,
          row.simulatorId,
          _formatDuration(row.result.runtime),
        );

    // The suite-shared "long-press = right-click" wrapper: right-click on
    // desktop, long-press on touch platforms. SimCrux is desktop- and
    // web-only with no touch device-class system (see simcrux/CLAUDE.md
    // "There is no Device Class system"), so isTouchLayout is false and the
    // wrapper's platform fallback still enables long-press for a touch
    // browser reporting an iOS/Android TargetPlatform.
    return PlatformContextMenu(
      onContextMenu: (globalPosition) => _maybeShowRowMenu(
        context,
        ref,
        contextMenuBuilder,
        anchor: globalPosition,
      ),
      child: InkWell(
        onTap: () =>
            ref.read(selectedTestIdProvider.notifier).select(row.testId),
        excludeFromSemantics: true,
        canRequestFocus: false,
        child: Container(
          color: bg,
          child: Row(
            children: [
              SizedBox(
                width: _kCheckboxColumnWidth,
                // Enter is claimed here, below the framework's
                // `Enter → ActivateIntent`, so it opens the row instead of
                // toggling; Space still reaches the check box.
                child: Shortcuts(
                  shortcuts: const <ShortcutActivator, Intent>{
                    SingleActivator(LogicalKeyboardKey.enter):
                        _InspectRowIntent(),
                    SingleActivator(LogicalKeyboardKey.numpadEnter):
                        _InspectRowIntent(),
                  },
                  child: Actions(
                    actions: <Type, Action<Intent>>{
                      _InspectRowIntent: CallbackAction<_InspectRowIntent>(
                        onInvoke: (_) {
                          ref
                              .read(selectedTestIdProvider.notifier)
                              .select(row.testId);
                          return null;
                        },
                      ),
                    },
                    child: Checkbox(
                      value: selected,
                      visualDensity: VisualDensity.compact,
                      semanticLabel: spoken,
                      onChanged: (_) => ref
                          .read(dashboardSelectionProvider.notifier)
                          .toggle(row.testId),
                    ),
                  ),
                ),
              ),
              Expanded(
                // Widths follow the header's, from the shared layout. Each
                // cell's own content is excluded from semantics (the check
                // box speaks for the row); the annotation is not, so its
                // tooltip stays readable.
                child: Row(
                  children: [
                    Expanded(
                      flex: layout.flexOf(DashboardSortColumn.status),
                      child: Center(
                        child: ExcludeSemantics(
                          child: DashboardStatusIcon(
                            status: row.result.status,
                            size: _kStatusIconSize,
                          ),
                        ),
                      ),
                    ),
                    // crux_table's text cell: the full value as a hover-only
                    // tooltip (a long-press trigger would claim the row's
                    // context-menu gesture on touch hosts), and the Pro
                    // annotation after the name, scaling down before it
                    // overflows a cell dragged narrow.
                    CruxTableCell(
                      text: row.suiteName,
                      flex: layout.flexOf(DashboardSortColumn.suite),
                    ),
                    CruxTableCell(
                      text: row.testName,
                      flex: layout.flexOf(DashboardSortColumn.testName),
                      annotation: trailing,
                    ),
                    CruxTableCell(
                      text: row.simulatorId,
                      flex: layout.flexOf(DashboardSortColumn.simulator),
                    ),
                    CruxTableCell(
                      text: _formatDuration(row.result.runtime),
                      flex: layout.flexOf(DashboardSortColumn.duration),
                    ),
                    CruxTableCell(
                      text: _formatTimestamp(row.result.startedAt),
                      flex: layout.flexOf(DashboardSortColumn.startedAt),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    if (d.inMilliseconds < 1000) return '${d.inMilliseconds}ms';
    if (d.inSeconds < 60) {
      final ms = d.inMilliseconds % 1000;
      return '${d.inSeconds}.${ms.toString().padLeft(3, '0').substring(0, 1)}s';
    }
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m}m ${s.toString().padLeft(2, '0')}s';
  }

  String _formatTimestamp(DateTime t) {
    // Compact HH:MM:SS UTC, deliberately locale-neutral.
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    final ss = t.second.toString().padLeft(2, '0');
    return '$hh:$mm:$ss';
  }

  /// Resolves the per-row context-menu entries via the active
  /// [dashboardRowContextMenuBuilderProvider] override and, when the
  /// builder produced any entries, surfaces them through `showMenu` at
  /// [anchor] (the global screen position from [PlatformContextMenu]).
  ///
  /// Open-core's default builder returns the empty list, so right-
  /// click / long-press are no-ops without any extra branching at the
  /// call site. The Pro overlay's CXP-originate submenu registers
  /// entries here.
  Future<void> _maybeShowRowMenu(
    BuildContext context,
    WidgetRef ref,
    DashboardRowContextMenuBuilder builder, {
    required Offset anchor,
  }) async {
    final entries = builder(context, ref, row);
    if (entries.isEmpty) return;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final overlaySize = overlay?.size ?? const Size(800, 600);
    await showMenu<void>(
      context: context,
      position: RelativeRect.fromLTRB(
        anchor.dx,
        anchor.dy,
        overlaySize.width - anchor.dx,
        overlaySize.height - anchor.dy,
      ),
      items: entries,
    );
  }
}

/// Opens a results row's test in the inspector — Enter on the row's check
/// box, the keyboard form of clicking the row.
class _InspectRowIntent extends Intent {
  const _InspectRowIntent();
}
