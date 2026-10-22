// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:simcrux/features/flow/gls_labels.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/flow/gate_level/gls_outcome.dart';
import 'package:simcrux/services/flow/gate_level/gls_result.dart';

/// The explanation of a gate-level row in the inspector: the outcome and both
/// counts first, why a test did not run, which netlist and what kind of
/// simulation, the PDK banner and the version warning.
///
/// Free, like every gate-level outcome. Each sentence is its own selectable,
/// focusable line, fact first. Nothing renders for a row that is not gate
/// level.
class InspectorGlsNotes extends StatelessWidget {
  /// Creates the notes for [selection].
  const InspectorGlsNotes({required this.selection, super.key});

  /// The selected test.
  final SelectedTest selection;

  @override
  Widget build(BuildContext context) {
    final view = GlsResultView.of(selection.result);
    if (view == null) return const SizedBox.shrink();
    final l10n = L10N.of(context);
    final lines = glsNoteLines(l10n, view);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        key: const ValueKey('inspectorGlsNotes'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.inspectorSectionGateLevel,
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

/// One line of the gate-level notes.
typedef GlsNote = ({String text, bool title});

/// The lines [InspectorGlsNotes] shows for [view], in reading order: the
/// outcome with both counts, then why, then how it was simulated.
List<GlsNote> glsNoteLines(L10N l10n, GlsResultView view) {
  final notRun = view.outcome == GlsOutcome.notRun;
  return <GlsNote>[
    (text: GlsLabels.verdict(l10n, view), title: true),
    if (view.outcome == GlsOutcome.xOnly)
      (text: l10n.glsOutcomeXOnlyTooltip, title: false),
    if (notRun && view.reason != null)
      (text: GlsLabels.reason(l10n, view.reason!), title: false),
    if (view.bannered)
      (text: l10n.glsPdkBanner(view.pdk ?? view.target), title: false),
    if (view.versionDiffers) (text: l10n.glsVersionDiffers, title: false),
    if (view.rtlTest != null)
      (text: l10n.glsNoteRtlTest(view.rtlTest!), title: false),
    (
      text: view.netlist == 'pnl'
          ? l10n.glsNoteNetlistPnl
          : l10n.glsNoteNetlistNl,
      title: false,
    ),
    (text: l10n.glsNoteDelays, title: false),
    (text: l10n.glsNoteSimulator, title: false),
    if (!notRun && view.clock != null)
      (text: l10n.glsNoteClock(view.clock!), title: false),
    if (view.firstDiffPs != null)
      (text: l10n.glsNoteFirstDifference('${view.firstDiffPs}'), title: false),
  ];
}

/// One line of the notes: a Tab stop announced by its own text, with a focus
/// outline, and selectable for copying.
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
