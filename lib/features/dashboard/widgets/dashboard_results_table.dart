// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/features/dashboard/models/dashboard_column_layout.dart';
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
/// which the header's dividers drag.
const double _kCheckboxColumnWidth = 32;

/// Header and row height — LintCrux's violation-table density.
const double _kRowHeight = 28;

/// The status glyph's size in a [_kRowHeight] row.
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
                itemExtent: _kRowHeight,
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

class _DashboardHeaderRow extends ConsumerWidget {
  const _DashboardHeaderRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final theme = Theme.of(context);
    final layout = ref.watch(dashboardColumnLayoutProvider);
    final labels = <DashboardSortColumn, String>{
      DashboardSortColumn.status: l10n.dashboardColumnStatus,
      DashboardSortColumn.suite: l10n.dashboardColumnSuite,
      DashboardSortColumn.testName: l10n.dashboardColumnTest,
      DashboardSortColumn.simulator: l10n.dashboardColumnSimulator,
      DashboardSortColumn.duration: l10n.dashboardColumnDuration,
      DashboardSortColumn.startedAt: l10n.dashboardColumnStartedAt,
    };
    return Container(
      height: _kRowHeight,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          const SizedBox(width: _kCheckboxColumnWidth),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final tableWidth = constraints.maxWidth;
                return Row(
                  children: [
                    for (final column in DashboardColumnLayout.columns)
                      Expanded(
                        flex: layout.flexOf(column),
                        child: Row(
                          children: [
                            Expanded(
                              child: _SortableHeaderCell(
                                label: labels[column]!,
                                column: column,
                              ),
                            ),
                            if (column != DashboardColumnLayout.columns.last)
                              _ResizeHandle(
                                column: column,
                                tableWidth: tableWidth,
                              ),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SortableHeaderCell extends ConsumerWidget {
  const _SortableHeaderCell({required this.label, required this.column});

  final String label;
  final DashboardSortColumn column;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    final sort = ref.watch(dashboardSortProvider);
    final isActive = sort.column == column;

    // A button, not "text": the header sorts when activated, and a screen
    // reader only says so when the node carries the button role.
    return Semantics(
      button: true,
      container: true,
      child: InkWell(
        key: ValueKey('dashboardHeader-${column.name}'),
        onTap: () =>
            ref.read(dashboardSortProvider.notifier).toggleColumn(column),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Flexible(
                // The same header typography as LintCrux's violation table.
                child: Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Fixed-width, not Flexible: two Flexibles split the cell and
              // capped the label at half of it ("Simul…" in a column with
              // room for "Simulator"). Only the sorted column carries it, so
              // the others keep those 18 px for their label.
              if (isActive)
                Icon(
                  sort.direction == DashboardSortDirection.ascending
                      ? Icons.arrow_drop_up
                      : Icons.arrow_drop_down,
                  size: 18,
                  color: color,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The divider on a header cell's right edge: drag it to move width between
/// this column and the next, double-click it to restore the default widths.
///
/// Pointer-only and excluded from semantics. It is not a Tab stop, so the
/// table's keyboard order and what a screen reader announces are unchanged;
/// the default widths keep every column readable without it.
class _ResizeHandle extends ConsumerWidget {
  const _ResizeHandle({required this.column, required this.tableWidth});

  final DashboardSortColumn column;

  /// The width the resizable columns share, which turns a drag's pixels
  /// into weight.
  final double tableWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(dashboardColumnLayoutProvider.notifier);
    final color = Theme.of(context).colorScheme.outlineVariant;
    return ExcludeSemantics(
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        child: GestureDetector(
          key: ValueKey('dashboardResize-${column.name}'),
          behavior: HitTestBehavior.opaque,
          // Count movement from pointer-down, so the divider stays under
          // the cursor instead of lagging by the drag threshold.
          dragStartBehavior: DragStartBehavior.down,
          onHorizontalDragUpdate: (d) =>
              notifier.resize(column, d.delta.dx, tableWidth),
          onHorizontalDragEnd: (_) => notifier.commit(),
          onDoubleTap: notifier.reset,
          child: SizedBox(
            width: 8,
            height: _kRowHeight,
            child: Center(
              child: SizedBox(
                width: 1,
                height: 16,
                child: ColoredBox(color: color),
              ),
            ),
          ),
        ),
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
                    _BodyCell(
                      text: row.suiteName,
                      flex: layout.flexOf(DashboardSortColumn.suite),
                    ),
                    _BodyCell(
                      text: row.testName,
                      flex: layout.flexOf(DashboardSortColumn.testName),
                      annotation: trailing,
                    ),
                    _BodyCell(
                      text: row.simulatorId,
                      flex: layout.flexOf(DashboardSortColumn.simulator),
                    ),
                    _BodyCell(
                      text: _formatDuration(row.result.runtime),
                      flex: layout.flexOf(DashboardSortColumn.duration),
                    ),
                    _BodyCell(
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

class _BodyCell extends StatelessWidget {
  const _BodyCell({required this.text, required this.flex, this.annotation});

  final String text;
  final int flex;

  /// Drawn after [text], right-aligned (the Pro flaky chip in the Test
  /// cell). It takes its natural width and the text ellipsizes before it;
  /// in a cell too narrow for both it scales down rather than overflowing.
  final Widget? annotation;

  /// The text keeps at least this much of the cell beside an annotation.
  static const double _minTextWidth = 24;
  static const double _gap = 6;

  @override
  Widget build(BuildContext context) {
    // The full value on hover, so a cell dragged narrow is still readable.
    // Hover only: a tooltip's default long-press trigger would claim the
    // long-press the row uses for its context menu on touch hosts.
    final label = ExcludeSemantics(
      child: Tooltip(
        message: text,
        triggerMode: TooltipTriggerMode.manual,
        child: Text(
          text,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
    final annotation = this.annotation;
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: annotation == null
            ? Align(alignment: Alignment.centerLeft, child: label)
            : LayoutBuilder(
                builder: (context, constraints) {
                  final room = constraints.maxWidth - _gap - _minTextWidth;
                  return Row(
                    children: [
                      Expanded(child: label),
                      if (room > 0) ...[
                        const SizedBox(width: _gap),
                        ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: room),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerRight,
                            child: annotation,
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
      ),
    );
  }
}
