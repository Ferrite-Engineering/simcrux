// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:math' as math;

import 'package:crux_flow/crux_flow.dart';
import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:crux_license/crux_license.dart' show LicenseTier;
import 'package:crux_table/crux_table.dart';
import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/flow/flow_actions.dart';
import 'package:simcrux/features/flow/flow_labels.dart';
import 'package:simcrux/features/flow/providers/flow_pro_seams.dart';
import 'package:simcrux/features/flow/providers/flow_providers.dart';
import 'package:simcrux/features/flow/providers/flow_table_layouts.dart';
import 'package:simcrux/features/flow/widgets/flow_dialogs.dart';
import 'package:simcrux/features/flow/widgets/flow_keyboard_table.dart';
import 'package:simcrux/features/flow/widgets/flow_path_actions.dart';
import 'package:simcrux/features/remote/services/flow_path_selection.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/flow/flow_run_index.dart';
import 'package:simcrux/services/flow/flow_run_reading.dart';
import 'package:simcrux/services/flow/flow_worst_paths.dart';
import 'package:simcrux/shared/widgets/simcrux_feature_tier_badge.dart';

/// The Flow Runs panel: the project's implementation-flow runs, newest
/// first, and the selected run's verdict, steps, metrics and worst paths.
///
/// A dock tab (View > Flow Runs), movable between the bottom and right
/// docks; its close button hides it. Built inside the tab's provider scope,
/// so it lists that tab's runs. Everything here is open core: results are
/// findings, not signoff, and none of them is behind a tier.
class FlowRunsPanel extends ConsumerWidget {
  /// Creates the panel.
  const FlowRunsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    // Kept alive while the panel shows: re-reads the runs while a
    // regression is in flight.
    ref.watch(flowRunWatcherProvider);
    final config = ref.watch(activeConfigProvider);
    if (config == null) {
      return CruxPanelEmptyState(message: l10n.flowRunsNoProject);
    }
    final root = flowProjectRoot(config);
    final index = ref.watch(flowRunIndexProvider(root));
    final value = index.value;
    if (value == null) {
      return CruxPanelEmptyState(
        message: index.hasError
            ? l10n.flowRunsReadFailed
            : l10n.flowRunsReading,
      );
    }
    if (value.runs.isEmpty) {
      return CruxPanelEmptyState(
        message: l10n.flowRunsEmpty,
        icon: Icons.route_outlined,
        action: OutlinedButton(
          onPressed: () => _dispatch(context, SimcruxAction.ingestRunDirectory),
          child: Text(SimcruxAction.ingestRunDirectory.label(l10n)),
        ),
      );
    }
    return _FlowRunsBody(root: root, index: value);
  }
}

void _dispatch(BuildContext context, SimcruxAction action) =>
    Actions.maybeInvoke<SimcruxActionIntent>(
      context,
      SimcruxActionIntent(action),
    );

/// The delay-annotated gate-level run of the selected run, handed to the
/// installed runner from inside this tab's scope.
void _runWithDelays(BuildContext context, WidgetRef ref) => unawaited(
  FlowActions.runGateLevelWithDelays(
    context,
    ProviderScope.containerOf(context, listen: false),
    ref.read,
  ),
);

class _FlowRunsBody extends ConsumerWidget {
  const _FlowRunsBody({required this.root, required this.index});

  final String root;
  final FlowRunIndex index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final selection = ref.watch(flowSelectedRunProvider);
    final current = index.byRoot(selection?.root) ?? index.runs.first;
    if (selection == null || index.byRoot(selection.root) == null) {
      // Nothing chosen yet (or the choice is gone): the newest run is the
      // one shown, and the one the hand-off and Run Flow Entry act on.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        final now = ref.read(flowSelectedRunProvider);
        if (now != null && index.byRoot(now.root) != null) return;
        ref
            .read(flowSelectedRunProvider.notifier)
            .select(flowSelectionOf(current.reading.run.ref, current.design));
      });
    }
    // A status change of the shown run is spoken: the desktop bridges do
    // not announce a changed label on their own.
    ref.listen<AsyncValue<FlowRunIndex>>(flowRunIndexProvider(root), (
      previous,
      next,
    ) {
      final before = previous?.value?.byRoot(current.root);
      final after = next.value?.byRoot(current.root);
      if (before == null || after == null) return;
      if (before.reading.verdict == after.reading.verdict) return;
      announceCrux(
        context,
        l10n.flowRunStatusChanged(
          after.design,
          FlowLabels.verdict(l10n, after.reading),
        ),
      );
    });

    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 640;
        final list = _RunList(index: index, current: current);
        final detail = _RunDetail(
          key: ValueKey<String>(current.root),
          entry: current,
          previous: index.previousOf(current),
          problems: index.problems,
        );
        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: math.min(340, box.maxWidth * 0.38),
                child: list,
              ),
              const VerticalDivider(width: 1),
              Expanded(child: detail),
            ],
          );
        }
        final listHeight = math.max(
          kCruxTableRowHeight * 2,
          math.min(168, box.maxHeight * 0.4),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: listHeight.toDouble(), child: list),
            const Divider(height: 1),
            Expanded(child: detail),
          ],
        );
      },
    );
  }
}

class _RunList extends ConsumerWidget {
  const _RunList({required this.index, required this.current});

  final FlowRunIndex index;
  final FlowRunIndexEntry current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final layout = ref.watch(flowRunColumnLayout.layout);
    final runs = index.runs;
    return FlowKeyboardTable<FlowRunColumn>(
      tableId: 'flowRuns',
      semanticLabel: l10n.flowRunsTableLabel,
      layout: layout,
      controller: ref.read(flowRunColumnLayout.layout.notifier),
      headerLabels: <FlowRunColumn, String>{
        FlowRunColumn.verdict: l10n.flowColumnVerdict,
        FlowRunColumn.design: l10n.flowColumnDesign,
        FlowRunColumn.tag: l10n.flowColumnTag,
        FlowRunColumn.kind: l10n.flowColumnFlow,
      },
      rowCount: runs.length,
      currentIndex: runs.indexOf(current),
      // The run's context menu: rerun the entry's tests against this run's
      // netlist, at gate level. LibreLane runs only; free on every tier.
      contextMenuEntries: (i) {
        final run = runs[i];
        final librelane = run.reading.run.ref.kind == FlowKind.librelane;
        final delays = ref.read(flowSdfGlsRunnerProvider);
        void select() => ref
            .read(flowSelectedRunProvider.notifier)
            .select(flowSelectionOf(run.reading.run.ref, run.design));
        return <CruxMenuEntry>[
          CruxMenuItem(
            key: const ValueKey('flowRunRunGateLevel'),
            label: SimcruxAction.runGateLevelSimulation.label(l10n),
            icon: Icons.memory_outlined,
            enabled: librelane,
            onSelected: () {
              select();
              _dispatch(context, SimcruxAction.runGateLevelSimulation);
            },
          ),
          // The delay-annotated run, when an edition installs one: its label
          // is the edition's, and it owns its own tier gate.
          if (delays != null)
            CruxMenuItem(
              key: const ValueKey('flowRunRunGateLevelWithDelays'),
              label: delays.label(context),
              icon: Icons.timer_outlined,
              enabled: librelane,
              trailingBuilder: (_) =>
                  const SimCruxFeatureTierBadge(requiredTier: LicenseTier.pro),
              onSelected: () {
                select();
                _runWithDelays(context, ref);
              },
            ),
        ];
      },
      onCurrentChanged: (i) {
        final run = runs[i];
        ref
            .read(flowSelectedRunProvider.notifier)
            .select(flowSelectionOf(run.reading.run.ref, run.design));
      },
      rowLabel: (i) {
        final run = runs[i];
        return l10n.flowRunRowSpoken(
          run.design,
          run.reading.run.ref.tag,
          FlowLabels.verdict(l10n, run.reading),
          FlowLabels.kind(run.reading.run.ref.kind),
        );
      },
      cellsBuilder: (context, i) {
        final run = runs[i];
        return <Widget>[
          CruxTableCell(
            text: FlowLabels.verdict(l10n, run.reading),
            flex: layout.flexOf(FlowRunColumn.verdict),
            annotation: _VerdictGlyph(verdict: run.reading.verdict),
          ),
          CruxTableCell(
            text: run.design,
            flex: layout.flexOf(FlowRunColumn.design),
          ),
          CruxTableCell(
            text: run.reading.run.ref.tag,
            tooltip: run.root,
            flex: layout.flexOf(FlowRunColumn.tag),
          ),
          CruxTableCell(
            text: FlowLabels.kind(run.reading.run.ref.kind),
            flex: layout.flexOf(FlowRunColumn.kind),
          ),
        ];
      },
    );
  }
}

/// The verdict's shape, beside its word: the word carries the meaning, the
/// shape repeats it, and a violated run on a completed flow is a finding,
/// never painted as an error.
class _VerdictGlyph extends StatelessWidget {
  const _VerdictGlyph({required this.verdict});

  final FlowVerdict verdict;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = switch (verdict) {
      FlowVerdict.met => Icons.check_circle_outline,
      FlowVerdict.violated => Icons.report_outlined,
      FlowVerdict.stopped => Icons.stop_circle_outlined,
      FlowVerdict.notRun => Icons.remove_circle_outline,
      FlowVerdict.unrecognised => Icons.help_outline,
    };
    return ExcludeSemantics(
      child: Icon(icon, size: 14, color: scheme.onSurfaceVariant),
    );
  }
}

enum _Section { steps, metrics, paths }

class _RunDetail extends ConsumerStatefulWidget {
  const _RunDetail({
    required this.entry,
    required this.previous,
    required this.problems,
    super.key,
  });

  final FlowRunIndexEntry entry;
  final FlowRunIndexEntry? previous;
  final List<String> problems;

  @override
  ConsumerState<_RunDetail> createState() => _RunDetailState();
}

class _RunDetailState extends ConsumerState<_RunDetail> {
  _Section _section = _Section.steps;

  @override
  void initState() {
    super.initState();
    // A peer's "Show timing paths through this register" lands on the
    // paths, already filtered.
    if (ref.read(flowPathRegisterFilterProvider) != null) {
      _section = _Section.paths;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    final reading = widget.entry.reading;
    ref.listen<String?>(flowPathRegisterFilterProvider, (_, next) {
      if (next != null && _section != _Section.paths) {
        setState(() => _section = _Section.paths);
      }
    });
    return LayoutBuilder(
      builder: (context, box) {
        // The table keeps a usable height however short the dock is; the
        // whole detail scrolls instead of overflowing.
        final tableHeight = math.max(
          kCruxTableRowHeight * 6,
          box.maxHeight - 132,
        );
        return SingleChildScrollView(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!reading.run.ref.verified) const _ReaderBanner(),
              _Summary(entry: widget.entry, previous: widget.previous),
              if (widget.problems.isNotEmpty)
                Tooltip(
                  message: widget.problems.join('\n'),
                  child: Text(
                    l10n.flowRunsProblems(widget.problems.length),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              // Scrolls sideways in a dock narrower than its three labels
              // (the right dock, a long translation) rather than overflowing.
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: CruxSegmentedControl<_Section>(
                  dense: true,
                  semanticLabel: l10n.flowSectionsLabel,
                  selected: _section,
                  onChanged: (s) => setState(() => _section = s),
                  segments: [
                    CruxSegment(
                      value: _Section.steps,
                      label: l10n.flowStepsTableLabel,
                    ),
                    CruxSegment(
                      value: _Section.metrics,
                      label: l10n.flowMetricsTableLabel,
                    ),
                    CruxSegment(
                      value: _Section.paths,
                      label: l10n.flowPathsTableLabel,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: tableHeight,
                child: switch (_section) {
                  _Section.steps => _StepsTable(reading: reading),
                  _Section.metrics => _MetricsTable(reading: reading),
                  _Section.paths => _PathsTable(entry: widget.entry),
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Said first, before the verdict, whenever the reader was not verified
/// against the run's tool version: the result is read best-effort, never
/// presented as verified. A banner, not a beta label.
class _ReaderBanner extends StatelessWidget {
  const _ReaderBanner();

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('flowReaderNotVerified'),
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: Icon(
              Icons.info_outline,
              size: 16,
              color: scheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.flowReaderNotVerified,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Summary extends ConsumerWidget {
  const _Summary({required this.entry, required this.previous});

  final FlowRunIndexEntry entry;
  final FlowRunIndexEntry? previous;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final theme = Theme.of(context);
    final reading = entry.reading;
    final ref0 = reading.run.ref;
    final delta = flowRunDelta(reading, previous?.reading);
    final delays = ref.watch(flowSdfGlsRunnerProvider);
    final handoff = switch (ref0.kind) {
      FlowKind.librelane => <SimcruxAction>[
        SimcruxAction.openInKlayout,
        SimcruxAction.openInOpenroad,
        SimcruxAction.runGateLevelSimulation,
      ],
      FlowKind.nextpnr => <SimcruxAction>[SimcruxAction.openInNextpnrGui],
    };
    return Wrap(
      spacing: 12,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          l10n.flowRunHeading(
            entry.design,
            FlowLabels.verdict(l10n, reading),
          ),
          style: theme.textTheme.titleSmall,
        ),
        Text(
          l10n.flowFindingsNote,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(
          l10n.flowReaderLine(reading.reader, ref0.readerVersion),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (delta != null) FlowDeltaChip(delta: delta),
        for (final action in handoff)
          OutlinedButton(
            key: ValueKey<String>('flowPanel.${action.name}'),
            onPressed: () {
              ref
                  .read(flowSelectedRunProvider.notifier)
                  .select(flowSelectionOf(ref0, entry.design));
              _dispatch(context, action);
            },
            child: Text(action.label(l10n)),
          ),
        if (delays != null && ref0.kind == FlowKind.librelane)
          OutlinedButton(
            key: const ValueKey<String>('flowPanel.runGateLevelWithDelays'),
            onPressed: () {
              ref
                  .read(flowSelectedRunProvider.notifier)
                  .select(flowSelectionOf(ref0, entry.design));
              _runWithDelays(context, ref);
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(delays.label(context)),
                const SizedBox(width: 6),
                const SimCruxFeatureTierBadge(requiredTier: LicenseTier.pro),
              ],
            ),
          ),
      ],
    );
  }
}

/// The last-run delta: this run against the previous run of the same
/// design, on worst slack (or the achieved clock when there is no slack).
/// Open core: one number against the run before is a property of the
/// result, not accumulated history.
///
/// The words say better or worse and by how much; the arrow repeats them,
/// so colour is never the only channel. Its spoken name says the unit in
/// full.
class FlowDeltaChip extends StatelessWidget {
  /// Creates the chip.
  const FlowDeltaChip({required this.delta, super.key});

  /// The comparison.
  final FlowRunDelta delta;

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    final scheme = Theme.of(context).colorScheme;
    final improved = delta.improved;
    final amount = delta.change.abs();
    final String shown;
    final String spoken;
    switch ((delta.kind, improved)) {
      case (_, null):
        shown = l10n.flowDeltaSame;
        spoken = l10n.flowDeltaSame;
      case (FlowDeltaKind.worstSlack, true):
        shown = l10n.flowDeltaSlackBetter(amount.toStringAsFixed(3));
        spoken = l10n.flowDeltaSlackBetterSpoken(amount.toStringAsFixed(3));
      case (FlowDeltaKind.worstSlack, false):
        shown = l10n.flowDeltaSlackWorse(amount.toStringAsFixed(3));
        spoken = l10n.flowDeltaSlackWorseSpoken(amount.toStringAsFixed(3));
      case (FlowDeltaKind.fmax, true):
        shown = l10n.flowDeltaFmaxBetter(amount.toStringAsFixed(2));
        spoken = l10n.flowDeltaFmaxBetterSpoken(amount.toStringAsFixed(2));
      case (FlowDeltaKind.fmax, false):
        shown = l10n.flowDeltaFmaxWorse(amount.toStringAsFixed(2));
        spoken = l10n.flowDeltaFmaxWorseSpoken(amount.toStringAsFixed(2));
    }
    final icon = switch (improved) {
      null => Icons.drag_handle,
      true => Icons.arrow_upward,
      false => Icons.arrow_downward,
    };
    return Semantics(
      container: true,
      label: spoken,
      child: ExcludeSemantics(
        child: Container(
          key: const ValueKey('flowDeltaChip'),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(shown, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

class _StepsTable extends ConsumerWidget {
  const _StepsTable({required this.reading});

  final FlowReading reading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final steps = reading.run.steps;
    if (steps.isEmpty) {
      return CruxPanelEmptyState(
        message: l10n.flowStepsNone,
        action: OutlinedButton(
          onPressed: () =>
              unawaited(FlowStepDetailDialog.show(context, run: reading.run)),
          child: Text(l10n.flowOpenRunLog),
        ),
      );
    }
    final layout = ref.watch(flowStepColumnLayout.layout);
    String runtime(FlowStep step) {
      final r = step.runtime;
      return r == null ? '' : (r.inMilliseconds / 1000).toStringAsFixed(1);
    }

    return FlowKeyboardTable<FlowStepColumn>(
      tableId: 'flowSteps',
      semanticLabel: l10n.flowStepsTableLabel,
      layout: layout,
      controller: ref.read(flowStepColumnLayout.layout.notifier),
      headerLabels: <FlowStepColumn, String>{
        FlowStepColumn.ordinal: l10n.flowColumnNumber,
        FlowStepColumn.step: l10n.flowColumnStep,
        FlowStepColumn.tool: l10n.flowColumnTool,
        FlowStepColumn.status: l10n.flowColumnStatus,
        FlowStepColumn.runtime: l10n.flowColumnSeconds,
      },
      rowCount: steps.length,
      rowLabel: (i) {
        final step = steps[i];
        final time = runtime(step);
        return l10n.flowStepRowSpoken(
          step.ordinal,
          step.id,
          FlowLabels.stepStatus(l10n, step.status),
          time.isEmpty ? l10n.flowRuntimeUnknown : l10n.flowSecondsSpoken(time),
        );
      },
      onActivate: (i) => unawaited(
        FlowStepDetailDialog.show(context, run: reading.run, step: steps[i]),
      ),
      cellsBuilder: (context, i) {
        final step = steps[i];
        return <Widget>[
          CruxTableCell(
            text: '${step.ordinal}',
            flex: layout.flexOf(FlowStepColumn.ordinal),
          ),
          CruxTableCell(
            text: step.id,
            flex: layout.flexOf(FlowStepColumn.step),
          ),
          CruxTableCell(
            text: step.tool,
            flex: layout.flexOf(FlowStepColumn.tool),
          ),
          CruxTableCell(
            text: FlowLabels.stepStatus(l10n, step.status),
            flex: layout.flexOf(FlowStepColumn.status),
          ),
          CruxTableCell(
            text: runtime(step),
            flex: layout.flexOf(FlowStepColumn.runtime),
          ),
        ];
      },
    );
  }
}

/// One row of the metrics table: a metric (its base and any modifier other
/// than the corner) and its value per column.
class _MetricRow {
  _MetricRow(this.key, this.base, this.modifiers);

  /// The METRICS2.1 key without its corner, shown in the tooltip.
  final String key;

  /// The base metric.
  final String base;

  /// The modifiers other than the corner (nextpnr's `bel:ICESTORM_LC`).
  final List<MetricModifier> modifiers;

  /// Column name (`''` for the design-wide value) to value.
  final Map<String, Object?> values = <String, Object?>{};

  /// The base's label, else the label of the base joined with its
  /// modifiers' names, the way nextpnr's resource keys are labelled.
  FlowMetricLabel? label(L10N l10n) =>
      FlowLabels.metric(l10n, base) ??
      (modifiers.isEmpty
          ? null
          : FlowLabels.metric(
              l10n,
              <String>[base, for (final m in modifiers) m.name].join('__'),
            ));

  /// The Metric cell: the label, with the modifiers' values after it so
  /// rows that share a label stay apart; null when SimCrux has no label.
  String? title(L10N l10n) {
    final text = label(l10n)?.label;
    if (text == null || modifiers.isEmpty) return text;
    return '$text, ${modifiers.map((m) => m.value).join(', ')}';
  }
}

class _MetricsTable extends StatefulWidget {
  const _MetricsTable({required this.reading});

  final FlowReading reading;

  @override
  State<_MetricsTable> createState() => _MetricsTableState();
}

class _MetricsTableState extends State<_MetricsTable>
    implements CruxColumnResizeController<FlowMetricColumn> {
  late List<_MetricRow> _rows;
  late List<String> _columns;
  late CruxColumnLayout<FlowMetricColumn> _layout;

  @override
  void initState() {
    super.initState();
    _build();
  }

  @override
  void didUpdateWidget(covariant _MetricsTable old) {
    super.didUpdateWidget(old);
    if (!identical(old.reading, widget.reading)) _build();
  }

  void _build() {
    final rows = <String, _MetricRow>{};
    final corners = <String>{};
    var design = false;
    for (final MapEntry(:key, :value) in widget.reading.run.metrics.entries) {
      final parsed = MetricKey.tryParse(key);
      if (parsed == null) continue;
      final corner = parsed.modifier('corner');
      final others = <MetricModifier>[
        for (final m in parsed.modifiers)
          if (m.name != 'corner') m,
      ];
      final rowKey = MetricKey(parsed.base, others).format();
      final row = rows.putIfAbsent(
        rowKey,
        () => _MetricRow(rowKey, parsed.base, others),
      );
      row.values[corner ?? ''] = value;
      if (corner == null) {
        design = true;
      } else {
        corners.add(corner);
      }
    }
    _rows = rows.values.toList();
    final sorted = corners.toList()..sort();
    _columns = <String>[
      if (design) '',
      ...sorted,
    ].take(kFlowMetricValueColumns.length).toList();
    final used = <FlowMetricColumn>[
      FlowMetricColumn.metric,
      for (var i = 0; i < _columns.length; i++) kFlowMetricValueColumns[i],
    ];
    _layout = CruxTableColumns<FlowMetricColumn>(
      columns: used,
      defaultWeights: <FlowMetricColumn, double>{
        FlowMetricColumn.metric: 2.4,
        for (final c in used.skip(1)) c: 1,
      },
    ).defaults;
  }

  @override
  void resize(FlowMetricColumn column, double dx, double tableWidth) =>
      setState(() => _layout = _layout.resize(column, dx, tableWidth));

  @override
  void commit() {}

  @override
  void reset() => setState(() => _layout = _layout.columns.defaults);

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    if (_rows.isEmpty) {
      return CruxPanelEmptyState(message: l10n.flowMetricsNone);
    }
    String columnName(int i) =>
        _columns[i].isEmpty ? l10n.flowMetricsColumnDesign : _columns[i];
    String shown(_MetricRow row, int i) {
      final value = row.values[_columns[i]];
      if (value == null) return '';
      final unit = row.label(l10n)?.unit;
      final text = FlowLabels.value(value);
      return unit == null ? text : '$text $unit';
    }

    return FlowKeyboardTable<FlowMetricColumn>(
      tableId: 'flowMetrics',
      semanticLabel: l10n.flowMetricsTableLabel,
      layout: _layout,
      controller: this,
      headerLabels: <FlowMetricColumn, String>{
        FlowMetricColumn.metric: l10n.flowColumnMetric,
        for (var i = 0; i < _columns.length; i++)
          kFlowMetricValueColumns[i]: columnName(i),
      },
      rowCount: _rows.length,
      rowLabel: (r) {
        final row = _rows[r];
        final label = row.label(l10n);
        final spokenUnit = label?.spokenUnit;
        final values = <String>[
          for (var i = 0; i < _columns.length; i++)
            if (row.values[_columns[i]] != null)
              l10n.flowMetricValueSpoken(
                columnName(i),
                spokenUnit == null
                    ? FlowLabels.value(row.values[_columns[i]])
                    : '${FlowLabels.value(row.values[_columns[i]])} $spokenUnit',
              ),
        ];
        return l10n.flowMetricRowSpoken(
          row.title(l10n) ?? row.key,
          values.join(', '),
        );
      },
      cellsBuilder: (context, r) {
        final row = _rows[r];
        final label = row.title(l10n);
        return <Widget>[
          CruxTableCell(
            text: label ?? row.key,
            // The metric key is the tool's own identifier, never translated:
            // the localized label shows, the key is one hover away.
            tooltip: row.key,
            flex: _layout.flexOf(FlowMetricColumn.metric),
          ),
          for (var i = 0; i < _columns.length; i++)
            CruxTableCell(
              text: shown(row, i),
              flex: _layout.flexOf(kFlowMetricValueColumns[i]),
            ),
        ];
      },
    );
  }
}

class _PathsTable extends ConsumerWidget {
  const _PathsTable({required this.entry});

  final FlowRunIndexEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final reading = entry.reading;
    final runRef = reading.run.ref;
    final async = ref.watch(
      flowWorstPathsProvider((run: runRef, design: entry.design)),
    );
    final paths = async.value;
    if (paths == null) {
      return CruxPanelEmptyState(
        message: async.hasError
            ? l10n.flowPathsUnreadable
            : l10n.flowPathsReading,
      );
    }
    final register = ref.watch(flowPathRegisterFilterProvider);
    final top = flowEntryNamed(
      ref.watch(activeConfigProvider),
      entry.design,
    )?.top;
    final rows = register == null
        ? paths.rows
        : <FlowPathRow>[
            for (final row in paths.rows)
              if (flowPathThroughRegister(row, register, top: top)) row,
          ];
    // A peer's "Show timing paths through this register": said, with the
    // way back, above whatever the filter leaves.
    final filterNote = register == null
        ? null
        : _RegisterFilterNote(register: register, matches: rows.length);
    if (paths.rows.isEmpty) {
      return CruxPanelEmptyState(
        message: switch (paths.gap) {
          FlowWorstPathsGap.librelaneNotRead => l10n.flowPathsLibreLane,
          FlowWorstPathsGap.unreadable => l10n.flowPathsUnreadable,
          _ => l10n.flowPathsNone,
        },
      );
    }
    if (rows.isEmpty) return filterNote!;
    final layout = ref.watch(flowPathColumnLayout.layout);
    FlowPathTarget targetOf(int i) =>
        flowPathTargetFor(ref.read, entry, rows[i]);
    void open(int i) {
      final row = rows[i];
      // Which kind of run and how well its path maps: never the path, its
      // cells, its delay or the design.
      ref
          .read(telemetryServiceProvider)
          .record(
            TelemetryEvent(
              'flow.path.opened',
              properties: <String, Object?>{
                'kind': runRef.kind.wireName,
                'fidelity': row.fidelity.wireName,
              },
            ),
          );
      unawaited(FlowPathDetailDialog.show(context, row));
    }

    final table = FlowKeyboardTable<FlowPathColumn>(
      tableId: 'flowPaths',
      semanticLabel: l10n.flowPathsTableLabel,
      layout: layout,
      controller: ref.read(flowPathColumnLayout.layout.notifier),
      headerLabels: <FlowPathColumn, String>{
        FlowPathColumn.rank: l10n.flowColumnNumber,
        FlowPathColumn.clock: l10n.flowColumnClock,
        FlowPathColumn.from: l10n.flowColumnFrom,
        FlowPathColumn.to: l10n.flowColumnTo,
        FlowPathColumn.delay: l10n.flowColumnDelay,
        FlowPathColumn.mapping: l10n.flowColumnMapping,
      },
      rowCount: rows.length,
      // Moving onto a path, or into the table, makes it what Cross-probe
      // Selection sends; the send announces the whole path to the peers.
      onCurrentChanged: (i) => focusFlowPath(ref, targetOf(i)),
      onFocusChanged: (i) {
        if (i >= 0) focusFlowPath(ref, targetOf(i));
      },
      contextMenuEntries: (i) => flowPathMenuEntries(context, ref, targetOf(i)),
      rowLabel: (i) {
        final row = rows[i];
        final path = row.path;
        final clock = path.clockTo ?? path.clockFrom;
        final delay = FlowLabels.nanoseconds(path.delayNs);
        final fidelity = FlowLabels.fidelity(l10n, row.fidelity);
        return clock == null
            ? l10n.flowPathRowSpokenNoClock(
                path.rank,
                path.startpoint,
                path.endpoint,
                delay,
                fidelity,
              )
            : l10n.flowPathRowSpoken(
                path.rank,
                clock,
                path.startpoint,
                path.endpoint,
                delay,
                fidelity,
              );
      },
      onActivate: open,
      cellsBuilder: (context, i) {
        final row = rows[i];
        final path = row.path;
        return <Widget>[
          CruxTableCell(
            text: '${path.rank}',
            flex: layout.flexOf(FlowPathColumn.rank),
          ),
          CruxTableCell(
            text: path.clockTo ?? path.clockFrom ?? '',
            flex: layout.flexOf(FlowPathColumn.clock),
          ),
          CruxTableCell(
            text: path.startpoint,
            tooltip: FlowLabels.mapping(l10n, row.startpoint),
            flex: layout.flexOf(FlowPathColumn.from),
          ),
          CruxTableCell(
            text: path.endpoint,
            tooltip: FlowLabels.mapping(l10n, row.endpoint),
            flex: layout.flexOf(FlowPathColumn.to),
          ),
          CruxTableCell(
            text: FlowLabels.nanoseconds(path.delayNs),
            flex: layout.flexOf(FlowPathColumn.delay),
          ),
          CruxTableCell(
            text: FlowLabels.fidelity(l10n, row.fidelity),
            flex: layout.flexOf(FlowPathColumn.mapping),
          ),
        ];
      },
    );
    if (paths.mapped && filterNote == null) return table;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ?filterNote,
        if (!paths.mapped)
          Text(
            l10n.flowPathsUnmappedNote,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        const SizedBox(height: 4),
        Expanded(child: table),
      ],
    );
  }
}

/// "Paths through cnt_q" and the way back to every path: what a peer's
/// "Show timing paths through this register" left the table showing.
class _RegisterFilterNote extends ConsumerWidget {
  const _RegisterFilterNote({required this.register, required this.matches});

  final String register;
  final int matches;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final theme = Theme.of(context);
    return Padding(
      key: const ValueKey('flowPathRegisterFilter'),
      padding: const EdgeInsets.only(bottom: 4),
      child: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            matches == 0
                ? l10n.flowPathsNoneThroughRegister(register)
                : l10n.flowPathsThroughRegister(register),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          TextButton(
            key: const ValueKey('flowPathsShowAll'),
            onPressed: () =>
                ref.read(flowPathRegisterFilterProvider.notifier).clear(),
            child: Text(l10n.flowPathsShowAll),
          ),
        ],
      ),
    );
  }
}
