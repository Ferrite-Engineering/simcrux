// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:simcrux/domain/enums/formal_property_status.dart';
import 'package:simcrux/domain/models/formal_diagnostic.dart';
import 'package:simcrux/domain/models/formal_result_summary.dart';
import 'package:simcrux/features/dashboard/widgets/formal_verdict_label.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// The explanation of a formal row in the inspector: an EQY row's
/// partitions, why a row did not run (an SVA construct the frontend
/// refused, or properties it dropped), and whether its result depends on
/// state from before the trace began.
///
/// Free, like every formal verdict. Each sentence is its own selectable,
/// focusable line, in reading order with the **fact first**: the refused
/// construct and where it is, then why, then what can be done. A screen
/// reader reaches the construct before any advice.
///
/// It never says the property passed and never offers to rewrite it.
/// Nothing renders for a row with nothing to explain.
class InspectorFormalNotes extends StatelessWidget {
  /// Creates the notes for [selection].
  const InspectorFormalNotes({required this.selection, super.key});

  /// The selected test.
  final SelectedTest selection;

  @override
  Widget build(BuildContext context) {
    final metrics = selection.result.metrics;
    final summary = FormalResultSummary.fromMetrics(metrics);
    if (summary == null) return const SizedBox.shrink();
    final lines = formalNoteLines(
      L10N.of(context),
      summary,
      partitions: FormalResultSummary.partitionsOf(metrics),
    );
    if (lines.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        key: const ValueKey('inspectorFormalNotes'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            L10N.of(context).inspectorSectionFormal,
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: _NoteLine(text: line.text, title: line.title),
            ),
        ],
      ),
    );
  }
}

/// One line of the notes: a Tab stop announced by its own text, with a
/// focus outline, and selectable for copying.
class _NoteLine extends StatelessWidget {
  const _NoteLine({required this.text, required this.title});

  final String text;
  final bool title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Focus(
      child: Builder(
        builder: (context) {
          final focused = Focus.of(context).hasFocus;
          return Semantics(
            label: text,
            child: ExcludeSemantics(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: focused
                        ? theme.colorScheme.primary
                        : Colors.transparent,
                  ),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: SelectableText(
                    text,
                    style: title
                        ? theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          )
                        : theme.textTheme.bodySmall,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The most partitions [formalNoteLines] lists one by one; the rest are
/// counted on one line. Each line is a Tab stop, so the list stays short;
/// every partition is still in the row's metrics and the run log.
const int kInspectorMaxPartitionLines = 20;

/// The lines [InspectorFormalNotes] shows for [summary], in reading order.
/// Empty when there is nothing to explain.
///
/// An EQY row lists its partitions ([partitions], from
/// [FormalResultSummary.partitionsOf]): how many were proved equivalent,
/// then each partition with its own result, a counterexample with its trace
/// file. Which partitions were proved is always said, never implied by the
/// row's verdict.
List<({String text, bool title})> formalNoteLines(
  L10N l10n,
  FormalResultSummary summary, {
  List<FormalPartitionRow> partitions = const <FormalPartitionRow>[],
}) {
  final lines = <({String text, bool title})>[];
  if (partitions.isNotEmpty) {
    final proved = partitions
        .where((x) => x.status == FormalPropertyStatus.proved)
        .length;
    lines.add((
      text: l10n.formalEqyPartitionsHeading(proved, partitions.length),
      title: true,
    ));
    // The partitions that need attention first, each group in run order.
    final ordered = <FormalPartitionRow>[
      for (final rank in const <int>[3, 2, 1, 0])
        ...partitions.where((x) => x.status.conservativeRank == rank),
    ];
    for (final partition in ordered.take(kInspectorMaxPartitionLines)) {
      final trace = partition.trace;
      lines.add((
        text: switch (partition.status) {
          FormalPropertyStatus.proved ||
          FormalPropertyStatus.reached => l10n.formalEqyPartitionProved(
            partition.name,
          ),
          FormalPropertyStatus.counterexample ||
          FormalPropertyStatus.notReached =>
            trace == null
                ? l10n.formalEqyPartitionNotEquivalent(partition.name)
                : l10n.formalEqyPartitionCounterexample(partition.name, trace),
          FormalPropertyStatus.inconclusive => l10n.formalEqyPartitionUndecided(
            partition.name,
          ),
          FormalPropertyStatus.didNotRun => l10n.formalEqyPartitionDidNotRun(
            partition.name,
          ),
        },
        title: false,
      ));
    }
    if (partitions.length > kInspectorMaxPartitionLines) {
      lines.add((
        text: l10n.formalEqyPartitionsMore(
          partitions.length - kInspectorMaxPartitionLines,
        ),
        title: false,
      ));
    }
  }
  final refusal = summary.svaRefusal;
  if (summary.notRunReason == FormalNotRunReason.svaUnsupported &&
      refusal != null) {
    final what = formalSvaClassPhrase(l10n, refusal.constructClass);
    final location = refusal.location;
    final construct = refusal.construct;
    if (location != null) {
      lines.add((
        text: construct == null
            ? l10n.formalSvaAt(location, what)
            : l10n.formalSvaConstructAt(construct, location, what),
        title: true,
      ));
    }
    lines.add((text: l10n.formalVerdictDidNotRunSva, title: location == null));
    if (refusal.constructClass.temporal) {
      lines
        ..add((text: l10n.formalSvaTemporalHeadline, title: false))
        ..add((
          text: l10n.formalSvaUpstream(kSvaUpstreamReference),
          title: false,
        ));
    } else {
      lines.add((text: l10n.formalSvaOtherHeadline, title: false));
    }
    lines
      ..add((text: l10n.formalSvaVerific, title: false))
      ..add((text: l10n.formalSvaAdvice, title: false));
  } else if (summary.notRunReason == FormalNotRunReason.dropped) {
    lines
      ..add((text: l10n.formalVerdictDidNotRunDropped, title: true))
      ..add((text: l10n.formalDroppedExplanation, title: false));
  }
  final pretrace = summary.pretrace;
  if (pretrace != null) {
    lines.add((text: l10n.formalPretraceMarker, title: true));
    if (pretrace.location != null) {
      lines.add((
        text: l10n.formalPretraceLocation(pretrace.location!),
        title: false,
      ));
    }
    lines.add((
      text: pretrace.kind == 'cover'
          ? l10n.formalPretraceCoverExplanation(pretrace.step, pretrace.depth)
          : l10n.formalPretraceAssertExplanation(pretrace.step, pretrace.depth),
      title: false,
    ));
  }
  return lines;
}
