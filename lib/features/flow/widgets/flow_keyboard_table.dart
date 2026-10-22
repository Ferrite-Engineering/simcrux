// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:crux_table/crux_table.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A Flow table on `crux_table`: its header, its cells and its widths, with
/// the keyboard and screen-reader contract every Flow table shares.
///
/// - **One Tab stop.** The table is one focus node; the arrow keys, Home,
///   End, Page Up and Page Down move the current row. Enter or Space
///   activates it (opens the step, the path).
/// - **One announcement per row.** The table's node is named by
///   [semanticLabel] and its value is the current row's sentence
///   ([rowLabel]); moving speaks that sentence with `announceCrux`, because
///   the desktop bridges do not announce a value change on their own. The
///   cells are drawn for the eye and kept out of semantics.
/// - **Pointer.** A click makes a row current and focuses the table; a
///   double-click activates it. Rows are pointer targets only, never Tab
///   stops.
class FlowKeyboardTable<C extends Enum> extends StatefulWidget {
  /// Creates the table.
  const FlowKeyboardTable({
    required this.tableId,
    required this.semanticLabel,
    required this.layout,
    required this.headerLabels,
    required this.rowCount,
    required this.rowLabel,
    required this.cellsBuilder,
    this.controller,
    this.currentIndex,
    this.onCurrentChanged,
    this.onActivate,
    this.headerTooltips = const {},
    this.contextMenuEntries,
    this.onFocusChanged,
    super.key,
  });

  /// The context menu of row `index` (right-click on the row; Shift+F10 or
  /// the Menu key on the current row), or null for none.
  final List<CruxMenuEntry> Function(int index)? contextMenuEntries;

  /// Called with the current row when the table takes focus, and with -1
  /// when it loses it.
  final ValueChanged<int>? onFocusChanged;

  /// The table's name, the prefix of every key under it.
  final String tableId;

  /// The table's accessible name ("Worst paths").
  final String semanticLabel;

  /// The column widths.
  final CruxColumnLayout<C> layout;

  /// What the header dividers drive; null draws none.
  final CruxColumnResizeController<C>? controller;

  /// Each column's header label.
  final Map<C, String> headerLabels;

  /// Each column's header tooltip, when it has one (a unit, a raw key).
  final Map<C, String> headerTooltips;

  /// How many rows.
  final int rowCount;

  /// The one sentence a screen reader hears for row `index`.
  final String Function(int index) rowLabel;

  /// The visible cells of row `index`, each a `CruxTableCell` (or an
  /// `Expanded` of the same flex).
  final List<Widget> Function(BuildContext context, int index) cellsBuilder;

  /// The row that is current, when the host keeps it; the table keeps its
  /// own otherwise.
  final int? currentIndex;

  /// Called when the keyboard or a click makes another row current.
  final ValueChanged<int>? onCurrentChanged;

  /// Called when a row is activated (Enter, Space, double-click).
  final ValueChanged<int>? onActivate;

  @override
  State<FlowKeyboardTable<C>> createState() => _FlowKeyboardTableState<C>();
}

class _FlowKeyboardTableState<C extends Enum>
    extends State<FlowKeyboardTable<C>> {
  final FocusNode _focus = FocusNode(debugLabel: 'FlowKeyboardTable');
  final ScrollController _scroll = ScrollController();
  int _own = 0;

  int get _current {
    final n = widget.rowCount;
    if (n == 0) return -1;
    return (widget.currentIndex ?? _own).clamp(0, n - 1);
  }

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void dispose() {
    _focus
      ..removeListener(_onFocus)
      ..dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (!mounted) return;
    setState(() {});
    widget.onFocusChanged?.call(_focus.hasFocus ? _current : -1);
  }

  /// Opens the current row's context menu below the row, for Shift+F10 and
  /// the Menu key.
  void _openContextMenu() {
    final entries = widget.contextMenuEntries;
    final current = _current;
    if (entries == null || current < 0) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final scrolled = _scroll.hasClients ? _scroll.position.pixels : 0.0;
    final rowBottom =
        kCruxTableRowHeight * (current + 2) - scrolled; // header + row
    final local = Offset(
      kCruxTableCellPadding,
      rowBottom.clamp(0.0, box.size.height),
    );
    unawaited(
      showCruxContextMenu(
        context,
        globalPosition: box.localToGlobal(local),
        entries: entries(current),
      ),
    );
  }

  void _moveTo(int index, {bool speak = true}) {
    final n = widget.rowCount;
    if (n == 0) return;
    final next = index.clamp(0, n - 1);
    setState(() => _own = next);
    widget.onCurrentChanged?.call(next);
    _reveal(next);
    if (speak) announceCrux(context, widget.rowLabel(next));
  }

  int? _lastTapIndex;
  DateTime? _lastTapAt;

  void _onRowTap(int index) {
    final now = DateTime.now();
    final last = _lastTapAt;
    final second =
        _lastTapIndex == index &&
        last != null &&
        now.difference(last) <= kDoubleTapTimeout;
    _lastTapIndex = second ? null : index;
    _lastTapAt = second ? null : now;
    _focus.requestFocus();
    _moveTo(index, speak: false);
    if (second) widget.onActivate?.call(index);
  }

  void _reveal(int index) {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final top = index * kCruxTableRowHeight;
    final bottom = top + kCruxTableRowHeight;
    if (top < position.pixels) {
      position.jumpTo(top.clamp(0, position.maxScrollExtent));
    } else if (bottom > position.pixels + position.viewportDimension) {
      position.jumpTo(
        (bottom - position.viewportDimension).clamp(
          0,
          position.maxScrollExtent,
        ),
      );
    }
  }

  static bool get _modified {
    final keyboard = HardwareKeyboard.instance;
    return keyboard.isShiftPressed ||
        keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isAltPressed;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final n = widget.rowCount;
    if (n == 0) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final current = _current;
    const page = 10;
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveTo(current + 1);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _moveTo(current - 1);
    } else if (key == LogicalKeyboardKey.home) {
      _moveTo(0);
    } else if (key == LogicalKeyboardKey.end) {
      _moveTo(n - 1);
    } else if (key == LogicalKeyboardKey.pageDown) {
      _moveTo(current + page);
    } else if (key == LogicalKeyboardKey.pageUp) {
      _moveTo(current - page);
    } else if ((key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter ||
            key == LogicalKeyboardKey.space) &&
        !_modified) {
      // A bare Enter or Space only: Cmd/Ctrl+Shift+Enter is Cross-probe
      // Selection, which must reach the app's shortcuts.
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      widget.onActivate?.call(current);
    } else if (widget.contextMenuEntries != null &&
        (key == LogicalKeyboardKey.contextMenu ||
            (key == LogicalKeyboardKey.f10 &&
                HardwareKeyboard.instance.isShiftPressed))) {
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      _openContextMenu();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final current = _current;
    final focused = _focus.hasFocus;
    final value = current < 0 ? '' : widget.rowLabel(current);

    final header = ExcludeSemantics(
      child: CruxTableHeader<C>(
        tableId: widget.tableId,
        layout: widget.layout,
        controller: widget.controller,
        cellBuilder: (context, column) => _HeaderCell(
          label: widget.headerLabels[column] ?? column.name,
          tooltip: widget.headerTooltips[column],
        ),
      ),
    );

    final body = ListView.builder(
      controller: _scroll,
      itemExtent: kCruxTableRowHeight,
      itemCount: widget.rowCount,
      itemBuilder: (context, index) {
        final isCurrent = index == current;
        final menu = widget.contextMenuEntries;
        final row = GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          // A click selects at once; a second click on the same row within
          // the double-click time activates it. (An onDoubleTap would hold
          // every single click back by that time.)
          onTap: () => _onRowTap(index),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: isCurrent
                  ? scheme.primaryContainer.withValues(alpha: 0.5)
                  : null,
              // The focus is drawn as an outline on the current row, never
              // by colour alone: the row is also the one the reader names.
              border: isCurrent && focused
                  ? Border.all(color: scheme.primary, width: 1.5)
                  : null,
            ),
            child: Row(children: widget.cellsBuilder(context, index)),
          ),
        );
        if (menu == null) return row;
        // Right-click (or a long press on touch) opens this row's menu, the
        // one `CruxContextMenuRegion` opens, built when it opens; the
        // keyboard opens the current row's from the table's own key handler.
        return PlatformContextMenu(
          onContextMenu: (position) => unawaited(
            showCruxContextMenu(
              context,
              globalPosition: position,
              entries: menu(index),
            ),
          ),
          child: row,
        );
      },
    );

    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      includeSemantics: false,
      child: Semantics(
        key: ValueKey<String>('${widget.tableId}.semantics'),
        container: true,
        focusable: true,
        focused: focused,
        label: widget.semanticLabel,
        value: value,
        child: ExcludeSemantics(
          child: Column(
            children: [
              header,
              Expanded(child: body),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  const _HeaderCell({required this.label, this.tooltip});

  final String label;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelMedium?.copyWith(
        fontWeight: FontWeight.w600,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: kCruxTableCellPadding),
      child: Align(
        alignment: Alignment.centerLeft,
        child: tooltip == null
            ? text
            : Tooltip(
                message: tooltip,
                triggerMode: TooltipTriggerMode.manual,
                child: text,
              ),
      ),
    );
  }
}
