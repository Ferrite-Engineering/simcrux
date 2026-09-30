// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/inspector/providers/inspector_log_provider.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/result_store/log_buffer_store.dart';

/// Full-screen modal log viewer.
///
/// Surfaces the test's full stdout + stderr (interleaved in capture
/// order), severity-colored by simple prefix heuristics, with search
/// (Cmd/Ctrl+F-style next/prev navigation) and a jump-to-line input.
class LogViewerDialog extends ConsumerStatefulWidget {
  /// Creates a [LogViewerDialog].
  const LogViewerDialog({required this.selection, super.key});

  /// The currently-selected test snapshot.
  final SelectedTest selection;

  /// Convenience launcher: show the dialog with the selected test.
  ///
  /// The builder re-binds the CALLER's `ProviderContainer`. A dialog route
  /// is a child of the Navigator, which sits ABOVE the per-tab
  /// `UncontrolledProviderScope` (`simcrux_tab_overrides.dart` re-binds
  /// [fullInspectorLogProvider] per tab), so the dialog's own `ref` would
  /// otherwise resolve the ROOT container — whose log buffer store is empty
  /// for every test id. The viewer then rendered "No log output" over an
  /// inspector that was visibly streaming lines, and search / jump-to-line /
  /// Copy all operated on nothing.
  ///
  /// `containerOf` rather than "the active tab's container": [context] is
  /// the launching widget's own context, so this binds the tab the button
  /// actually lives in — correct even if the launch is not from the active
  /// tab.
  static Future<void> show(
    BuildContext context,
    SelectedTest selection,
  ) {
    final container = ProviderScope.containerOf(context, listen: false);
    return showDialog<void>(
      context: context,
      builder: (_) => UncontrolledProviderScope(
        container: container,
        child: LogViewerDialog(selection: selection),
      ),
    );
  }

  @override
  ConsumerState<LogViewerDialog> createState() => _LogViewerDialogState();
}

class _LogViewerDialogState extends ConsumerState<LogViewerDialog> {
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _jumpController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _searchFocus = FocusNode();
  final List<int> _matchIndices = <int>[];
  int _currentMatch = -1;
  String _activeQuery = '';
  static const double _kLineHeight = 18;

  @override
  void dispose() {
    _searchController.dispose();
    _jumpController.dispose();
    _scrollController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _recomputeMatches(List<LogLine> lines, String query) {
    _matchIndices.clear();
    _activeQuery = query;
    if (query.isEmpty) {
      _currentMatch = -1;
      return;
    }
    final needle = query.toLowerCase();
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].line.toLowerCase().contains(needle)) {
        _matchIndices.add(i);
      }
    }
    _currentMatch = _matchIndices.isEmpty ? -1 : 0;
    if (_currentMatch >= 0) _scrollToLine(_matchIndices[_currentMatch]);
  }

  void _stepMatch(int delta) {
    if (_matchIndices.isEmpty) return;
    setState(() {
      _currentMatch =
          (_currentMatch + delta + _matchIndices.length) % _matchIndices.length;
    });
    _scrollToLine(_matchIndices[_currentMatch]);
  }

  void _scrollToLine(int index) {
    if (!_scrollController.hasClients) return;
    final target = index * _kLineHeight;
    // Fire-and-forget: the animation completes after our state has
    // already updated; awaiting here would block the keyboard handler.
    // (No `discarded_futures` ignore needed — ScrollPosition.animateTo is
    // annotated `@awaitNotRequired`.)
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
    );
  }

  void _jumpToLineFromInput() {
    final raw = _jumpController.text.trim();
    final lineNumber = int.tryParse(raw);
    if (lineNumber == null || lineNumber < 1) return;
    _scrollToLine(lineNumber - 1);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    final theme = Theme.of(context);
    final lines = ref.watch(fullInspectorLogProvider(widget.selection.testId));

    // Keep match list aligned with the (possibly still streaming) line
    // count whenever the query changes.
    if (_activeQuery != _searchController.text) {
      _recomputeMatches(lines, _searchController.text);
    }

    // Clamp against the window so the dialog never exceeds small windows
    // (suite minimum is 800×500) — same idiom as `CruxSettingsShell`
    // (`math.min(cap, screen - margin)`).
    final screen = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(32),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: math.min<double>(1100, screen.width - 64),
          maxHeight: math.min<double>(760, screen.height - 64),
        ),
        child: Column(
          children: [
            _buildToolbar(context, l10n, theme, lines),
            const Divider(height: 1),
            Expanded(
              child: lines.isEmpty
                  ? Center(child: Text(l10n.logViewerEmpty))
                  : Scrollbar(
                      controller: _scrollController,
                      thumbVisibility: true,
                      child: ListView.builder(
                        controller: _scrollController,
                        itemCount: lines.length,
                        itemExtent: _kLineHeight,
                        itemBuilder: (context, index) => _LogLineRow(
                          index: index,
                          entry: lines[index],
                          isCurrentMatch:
                              _matchIndices.isNotEmpty &&
                              _currentMatch >= 0 &&
                              _matchIndices[_currentMatch] == index,
                          query: _activeQuery,
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar(
    BuildContext context,
    L10N l10n,
    ThemeData theme,
    List<LogLine> lines,
  ) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              l10n.logViewerTitle(widget.selection.testId),
              style: theme.textTheme.titleSmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 220,
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocus,
              decoration: InputDecoration(
                hintText: l10n.logViewerSearchHint,
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 16),
              ),
              onChanged: (q) {
                setState(() => _recomputeMatches(lines, q));
              },
              onSubmitted: (_) => _stepMatch(1),
            ),
          ),
          const SizedBox(width: 4),
          if (_matchIndices.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                l10n.logViewerMatchPosition(
                  _currentMatch + 1,
                  _matchIndices.length,
                ),
                style: theme.textTheme.labelSmall,
              ),
            ),
          IconButton(
            tooltip: l10n.logViewerSearchPrev,
            onPressed: _matchIndices.isEmpty ? null : () => _stepMatch(-1),
            icon: const Icon(Icons.keyboard_arrow_up),
          ),
          IconButton(
            tooltip: l10n.logViewerSearchNext,
            onPressed: _matchIndices.isEmpty ? null : () => _stepMatch(1),
            icon: const Icon(Icons.keyboard_arrow_down),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 80,
            child: TextField(
              controller: _jumpController,
              decoration: InputDecoration(
                hintText: l10n.logViewerJumpToLineHint,
                isDense: true,
              ),
              keyboardType: TextInputType.number,
              onSubmitted: (_) => _jumpToLineFromInput(),
            ),
          ),
          const SizedBox(width: 4),
          TextButton(
            onPressed: _jumpToLineFromInput,
            child: Text(l10n.logViewerJumpToLineGo),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: l10n.logViewerCopy,
            onPressed: lines.isEmpty
                ? null
                : () => Clipboard.setData(
                    ClipboardData(
                      text: lines.map((e) => e.line).join('\n'),
                    ),
                  ),
            icon: const Icon(Icons.copy_outlined),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.logViewerClose),
          ),
        ],
      ),
    );
  }
}

class _LogLineRow extends StatelessWidget {
  const _LogLineRow({
    required this.index,
    required this.entry,
    required this.isCurrentMatch,
    required this.query,
  });

  final int index;
  final LogLine entry;
  final bool isCurrentMatch;
  final String query;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color =
        _severityColor(entry.line, theme) ?? theme.textTheme.bodySmall?.color;
    final bg = isCurrentMatch
        ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
        : (index.isOdd ? theme.colorScheme.surfaceContainerLowest : null);
    return Container(
      height: 18,
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            child: Text(
              (index + 1).toString(),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontFamily: 'monospace',
              ),
              textAlign: TextAlign.right,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              entry.line,
              style: theme.textTheme.bodySmall?.copyWith(
                color: color,
                fontFamily: 'monospace',
                fontWeight: entry.fromStderr ? FontWeight.w600 : null,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  static Color? _severityColor(String line, ThemeData theme) {
    final lower = line.toLowerCase();
    if (lower.contains('error') ||
        lower.contains('fatal') ||
        lower.startsWith('uvm_error') ||
        lower.startsWith('uvm_fatal') ||
        lower.startsWith('%e')) {
      return theme.colorScheme.error;
    }
    if (lower.contains('warning') ||
        lower.startsWith('uvm_warning') ||
        lower.startsWith('%w')) {
      return Colors.amber;
    }
    if (lower.contains('info') ||
        lower.startsWith('uvm_info') ||
        lower.startsWith('%i')) {
      return theme.colorScheme.primary;
    }
    return null;
  }
}
