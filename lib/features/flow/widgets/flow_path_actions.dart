// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:crux_flow/crux_flow.dart';
import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/flow/providers/flow_providers.dart';
import 'package:simcrux/features/inspector/services/editor_launcher_provider.dart';
import 'package:simcrux/features/remote/services/flow_path_selection.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/flow/flow_run_index.dart';
import 'package:simcrux/services/flow/flow_worst_paths.dart';

/// The flow entry [design] names in [config], or null.
FlowEntry? flowEntryNamed(RegressionConfig? config, String design) {
  for (final entry in config?.flow?.entries ?? const <FlowEntry>[]) {
    if (entry.name == design) return entry;
  }
  return null;
}

/// The cross-probe target of [row], a worst path of the run [entry], in the
/// tab [read] reads from: the run, the row, the design's top (from its flow
/// entry) and the project's `crux.design_id`.
FlowPathTarget flowPathTargetFor(
  CruxCxpReader read,
  FlowRunIndexEntry entry,
  FlowPathRow row,
) {
  final config = read(activeConfigProvider);
  return FlowPathTarget(
    run: entry.reading.run.ref,
    row: row,
    design: entry.design,
    top: flowEntryNamed(config, entry.design)?.top,
    designId: config == null
        ? null
        : cxpDesignIdForPath(config.projectFilePath),
  );
}

/// Records [target] as the path the user is on: what Cross-probe Selection
/// sends next.
void focusFlowPath(WidgetRef ref, FlowPathTarget target) =>
    ref.read(flowFocusedPathProvider.notifier).focus(target);

/// The context menu of a worst-path row: "Cross-probe to" (the endpoint
/// register to WaveCrux and NetCrux, a statement to LintCrux), then "Open
/// statement in editor". Free on every tier.
List<CruxMenuEntry> flowPathMenuEntries(
  BuildContext context,
  WidgetRef ref,
  FlowPathTarget target,
) {
  final l10n = L10N.of(context);
  final statement = target.statements.isEmpty;
  return <CruxMenuEntry>[
    crossProbeMenuEntry(
      context,
      ref,
      selection: () {
        // The whole path to every peer as one `notify_selection` (gated, in
        // the shared helper, on "Broadcast selection automatically"), and the
        // one element the target's kind row picks to the target.
        focusFlowPath(ref, target);
        broadcastCruxCxpSelection(ref.read, flowPathNotifySelection(target));
        return flowPathCrossProbeSelection(target);
      },
    ),
    CruxMenuItem(
      key: const ValueKey('flowPathOpenStatement'),
      label: l10n.flowPathOpenStatement,
      icon: Icons.code,
      enabled: !statement,
      tooltip: statement ? l10n.flowPathNoStatement : null,
      onSelected: () => unawaited(openFlowPathStatement(context, ref, target)),
    ),
  ];
}

/// The design file a statement span names, resolved inside [projectRoot]:
/// the span's own path when it is inside the project, else the flow entry's
/// source it is a path suffix of (synthesis may have run elsewhere). Null
/// when neither is a file inside the project, symlinks resolved.
String? resolveFlowStatementFile(
  SrcSpan span, {
  required String projectRoot,
  Iterable<String> designSources = const <String>[],
}) {
  final containment = FlowContainment(<String>[projectRoot]);
  String? inside(String path) {
    if (!File(path).existsSync()) return null;
    try {
      return containment.require(path);
    } on FlowContainmentException {
      return null;
    }
  }

  final recorded = span.file;
  final direct = inside(
    p.isAbsolute(recorded) ? recorded : p.join(projectRoot, recorded),
  );
  if (direct != null) return direct;
  final sources = <String>[
    for (final s in designSources)
      p.normalize(p.isAbsolute(s) ? s : p.join(projectRoot, s)),
  ];
  final matched = matchSourceBySuffix(recorded, sources);
  return matched == null ? null : inside(matched);
}

/// "Open statement in editor": the path's first statement span (its
/// endpoint's first) at its line, in the user's editor, contained to the
/// project directory. The row keeps its mapping label; a span whose file is
/// not in the project is said in a toast, never opened.
Future<void> openFlowPathStatement(
  BuildContext context,
  WidgetRef ref,
  FlowPathTarget target,
) async {
  final l10n = L10N.of(context);
  final config = ref.read(activeConfigProvider);
  final spans = target.statements;
  if (config == null || spans.isEmpty) {
    showCruxErrorSnack(context, l10n.flowPathNoStatement);
    return;
  }
  final root = flowProjectRoot(config);
  final entry = flowEntryNamed(config, target.design ?? '');
  final span = spans.first;
  final file = resolveFlowStatementFile(
    span,
    projectRoot: root,
    designSources: entry?.sources ?? const <String>[],
  );
  if (file == null) {
    showCruxErrorSnack(context, l10n.flowPathStatementNotInProject);
    return;
  }
  final launcher = ref.read(editorLauncherProvider);
  final ok = await launcher.openSource(
    filePath: file,
    line: span.startLine,
    column: span.startCol ?? 1,
  );
  if (!ok && context.mounted) {
    final command = launcher.template.trim().split(RegExp(r'\s+')).first;
    showCruxErrorSnack(context, l10n.inspectorOpenSourceFailed(command));
  }
}
