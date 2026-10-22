// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:math' as math;

import 'package:crux_a11y/crux_a11y.dart';
import 'package:crux_flow/crux_flow.dart';
import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:crux_table/crux_table.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/flow/flow_labels.dart';
import 'package:simcrux/features/flow/providers/flow_providers.dart';
import 'package:simcrux/features/flow/providers/flow_table_layouts.dart';
import 'package:simcrux/features/flow/widgets/flow_keyboard_table.dart';
import 'package:simcrux/features/inspector/services/editor_launcher_provider.dart';
import 'package:simcrux/features/workspace/services/active_tab_scope.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/flow/flow_worst_paths.dart';

/// A step of a flow run (or, for a run with no steps, the run itself):
/// its status, a bounded tail of its log, and the full log in the editor.
///
/// Tab-modal: pushed on the tab's own navigator, so it reads the tab and
/// belongs to it.
class FlowStepDetailDialog extends ConsumerStatefulWidget {
  /// Creates the dialog for [step] of [run]; the run's own log when [step]
  /// is null.
  const FlowStepDetailDialog({required this.run, this.step, super.key});

  /// The run.
  final FlowRun run;

  /// The step, or null for the run's own log.
  final FlowStep? step;

  /// Shows the dialog on the tab [context] is in.
  static Future<void> show(
    BuildContext context, {
    required FlowRun run,
    FlowStep? step,
  }) => showCruxDialog<void>(
    context: context,
    navigator: ActiveTab.navigatorFor(context),
    modalGuardKey: ActiveTab.guardKey(context, 'flowStepDetail'),
    builder: (_) => FlowStepDetailDialog(run: run, step: step),
  );

  @override
  ConsumerState<FlowStepDetailDialog> createState() =>
      _FlowStepDetailDialogState();
}

class _FlowStepDetailDialogState extends ConsumerState<FlowStepDetailDialog> {
  late final String? _logPath = flowStepLogPath(widget.run, widget.step);
  Future<FlowLogTail>? _tail;

  @override
  void initState() {
    super.initState();
    final path = _logPath;
    if (path != null) _tail = readFlowLogTail(path);
  }

  Future<void> _openInEditor() async {
    final path = _logPath;
    if (path == null) return;
    final launcher = ref.read(editorLauncherProvider);
    final ok = await launcher.openSource(filePath: path);
    if (ok || !mounted) return;
    final command = launcher.template.trim().split(RegExp(r'\s+')).first;
    showCruxErrorSnack(
      context,
      L10N.of(context).inspectorOpenSourceFailed(command),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    final theme = Theme.of(context);
    final step = widget.step;
    final title = step == null
        ? l10n.flowRunLogTitle(widget.run.ref.tag)
        : l10n.flowStepDetailTitle(step.ordinal, step.id);
    final screen = MediaQuery.sizeOf(context);
    final logHeight = math.max<double>(
      120,
      math.min<double>(420, screen.height - 260),
    );
    return CruxDialog(
      title: title,
      width: 820,
      actions: [
        CruxDialogAction(
          label: l10n.flowOpenFullLog,
          onPressed: _logPath == null ? null : () => unawaited(_openInEditor()),
        ),
        CruxDialogAction(
          label: l10n.dialogClose,
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (step != null)
            Text(
              l10n.flowStepStatusLine(
                FlowLabels.stepStatus(l10n, step.status),
                step.tool,
              ),
            ),
          const SizedBox(height: 8),
          if (_tail == null)
            Text(
              l10n.flowLogNone,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            FutureBuilder<FlowLogTail>(
              future: _tail,
              builder: (context, snapshot) {
                final tail = snapshot.data;
                if (tail == null) return SizedBox(height: logHeight);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (tail.truncated)
                      Text(
                        l10n.inspectorLogPreviewLineCount(tail.lines.length),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    SizedBox(
                      height: logHeight,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: theme.colorScheme.outlineVariant,
                          ),
                        ),
                        child: CruxScrollRegion(
                          semanticLabel: l10n.flowLogTailLabel,
                          builder: (context, controller) => ListView.builder(
                            controller: controller,
                            itemCount: tail.lines.length,
                            itemExtent: 18,
                            padding: const EdgeInsets.all(8),
                            itemBuilder: (context, i) => Text(
                              tail.lines[i],
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}

/// One worst path as a list of rows: its segments, each with its delay and
/// where it lands in the RTL. A list, never a drawing.
///
/// Tab-modal, like [FlowStepDetailDialog].
class FlowPathDetailDialog extends ConsumerWidget {
  /// Creates the dialog for [row].
  const FlowPathDetailDialog({required this.row, super.key});

  /// The path and its mapping.
  final FlowPathRow row;

  /// Shows the dialog on the tab [context] is in.
  static Future<void> show(BuildContext context, FlowPathRow row) =>
      showCruxDialog<void>(
        context: context,
        navigator: ActiveTab.navigatorFor(context),
        modalGuardKey: ActiveTab.guardKey(context, 'flowPathDetail'),
        builder: (_) => FlowPathDetailDialog(row: row),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final path = row.path;
    final layout = ref.watch(flowSegmentColumnLayout.layout);
    final screen = MediaQuery.sizeOf(context);
    final height = math.max<double>(
      140,
      math.min<double>(420, screen.height - 260),
    );
    final delay = FlowLabels.nanoseconds(path.delayNs);
    final clock = path.clockTo ?? path.clockFrom;
    return CruxDialog(
      title: l10n.flowPathDetailTitle(path.rank),
      width: 900,
      actions: [
        CruxDialogAction(
          label: l10n.dialogClose,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.flowPathFromTo(path.startpoint, path.endpoint)),
          Text(
            clock == null
                ? l10n.flowPathSummaryNoClock(delay)
                : l10n.flowPathSummary(delay, clock),
          ),
          Text(
            l10n.flowPathEnds(
              FlowLabels.mapping(l10n, row.startpoint),
              FlowLabels.mapping(l10n, row.endpoint),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: height,
            child: FlowKeyboardTable<FlowSegmentColumn>(
              tableId: 'flowSegments',
              semanticLabel: l10n.flowSegmentsTableLabel,
              layout: layout,
              controller: ref.read(flowSegmentColumnLayout.layout.notifier),
              headerLabels: <FlowSegmentColumn, String>{
                FlowSegmentColumn.type: l10n.flowColumnSegmentType,
                FlowSegmentColumn.from: l10n.flowColumnFrom,
                FlowSegmentColumn.to: l10n.flowColumnTo,
                FlowSegmentColumn.delay: l10n.flowColumnDelay,
                FlowSegmentColumn.source: l10n.flowColumnSource,
              },
              rowCount: path.segments.length,
              rowLabel: (i) {
                final s = path.segments[i];
                return l10n.flowSegmentRowSpoken(
                  i + 1,
                  s.rawType,
                  s.fromCell,
                  s.toCell,
                  FlowLabels.nanoseconds(s.delayNs),
                  _segmentSource(l10n, i),
                );
              },
              cellsBuilder: (context, i) {
                final s = path.segments[i];
                return <Widget>[
                  CruxTableCell(
                    text: s.rawType,
                    flex: layout.flexOf(FlowSegmentColumn.type),
                  ),
                  CruxTableCell(
                    text: s.fromCell,
                    flex: layout.flexOf(FlowSegmentColumn.from),
                  ),
                  CruxTableCell(
                    text: s.toCell,
                    flex: layout.flexOf(FlowSegmentColumn.to),
                  ),
                  CruxTableCell(
                    text: FlowLabels.nanoseconds(s.delayNs),
                    flex: layout.flexOf(FlowSegmentColumn.delay),
                  ),
                  CruxTableCell(
                    text: _segmentSource(l10n, i),
                    flex: layout.flexOf(FlowSegmentColumn.source),
                  ),
                ];
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Where segment [i] lands: its own mapping, or, when it has none, the
  /// nearest mapped neighbour's, said as such.
  String _segmentSource(L10N l10n, int i) {
    final own = row.segmentMapping(i);
    if (own.fidelity != MappingFidelity.unmapped) {
      return FlowLabels.mapping(l10n, own);
    }
    final mapping = TimingPathMapping(
      startpoint: row.startpoint,
      endpoint: row.endpoint,
      segments: row.segments,
    );
    final near = row.segments.isEmpty ? null : mapping.nearestMapped(i);
    if (near == null) return FlowLabels.mapping(l10n, own);
    return l10n.flowMappingNearest(
      FlowLabels.mapping(l10n, row.segments[near]),
    );
  }
}

/// Keeps [FlowRunSelection] in step with a run the user moved to.
FlowRunSelection flowSelectionOf(FlowRunRef ref, String design) =>
    FlowRunSelection(root: ref.root, kind: ref.kind, design: design);
