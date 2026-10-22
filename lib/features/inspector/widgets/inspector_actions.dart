// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';
import 'package:simcrux/domain/enums/waveform_capture_policy.dart';
import 'package:simcrux/domain/models/formal_result_summary.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/domain/models/waveform_policy.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/providers/regression_runner.dart';
import 'package:simcrux/features/inspector/dialogs/log_viewer_dialog.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/inspector/services/editor_launcher_provider.dart';
import 'package:simcrux/features/inspector/widgets/flow_handoff_buttons.dart';
import 'package:simcrux/features/remote/providers/notify_selection_emitter.dart';
import 'package:simcrux/features/remote/services/cross_probe_selection.dart';
import 'package:simcrux/features/remote/services/cross_probe_to_product.dart';
import 'package:simcrux/features/remote/services/debug_in_wavecrux_dispatcher.dart';
import 'package:simcrux/features/remote/services/debug_in_wavecrux_message.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/flow/gate_level/gls_result.dart';
import 'package:simcrux/services/remote/cxp/formal_stream_coordinate.dart';

/// The most per-partition WaveCrux hand-offs the inspector offers for one
/// EQY row; every partition's trace is still in the row's notes and log.
const int kInspectorMaxPartitionHandoffs = 8;

/// NetCrux's product name on CXP.
const String kNetcruxProductName = 'netcrux';

/// Row of action buttons in the inspector pane: open full log,
/// re-run, re-run forcing waveform, open testbench source, open
/// waveform in WaveCrux.
class InspectorActions extends ConsumerWidget {
  /// Creates an [InspectorActions].
  const InspectorActions({required this.selection, super.key});

  /// The currently-selected test snapshot.
  final SelectedTest selection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          onPressed: () => LogViewerDialog.show(context, selection),
          icon: const Icon(Icons.article_outlined),
          label: Text(l10n.inspectorActionOpenFullLog),
        ),
        OutlinedButton.icon(
          onPressed: () => _rerun(ref, context, forceWaveform: false),
          icon: const Icon(Icons.refresh),
          label: Text(l10n.inspectorActionRerun),
        ),
        OutlinedButton.icon(
          onPressed: () => _rerun(ref, context, forceWaveform: true),
          icon: const Icon(Icons.replay_circle_filled_outlined),
          label: Text(l10n.inspectorActionRerunWithWaveform),
        ),
        OutlinedButton.icon(
          onPressed: selection.spec == null
              ? null
              : () => _openSource(ref, context),
          icon: const Icon(Icons.code),
          label: Text(l10n.inspectorActionOpenSource),
        ),
        Tooltip(
          message: l10n.inspectorActionDebugInWavecruxTooltip,
          child: OutlinedButton.icon(
            onPressed: () => _debugInWaveCrux(ref, context),
            icon: const Icon(Icons.show_chart),
            label: Text(l10n.inspectorActionDebugInWavecrux),
          ),
        ),
        // One hand-off per failing EQY partition, each with its own trace
        // and the partition as the coordinate's `sub_id`.
        for (final partition in failingEqyPartitions(
          selection.result.metrics,
        ).take(kInspectorMaxPartitionHandoffs))
          OutlinedButton.icon(
            key: ValueKey<String>('debugPartition:${partition.name}'),
            onPressed: () =>
                _debugInWaveCrux(ref, context, partition: partition),
            icon: const Icon(Icons.show_chart),
            label: Text(
              l10n.inspectorActionDebugPartitionInWavecrux(partition.name),
            ),
          ),
        // A failing property's signal to NetCrux, with its fan-in.
        if (formalShowInNetCruxSelection(selection.result) != null)
          Tooltip(
            message: l10n.inspectorActionShowInNetcruxTooltip,
            child: Builder(
              builder: (buttonContext) => OutlinedButton.icon(
                key: const ValueKey('inspectorShowInNetcrux'),
                onPressed: () => unawaited(
                  crossProbeToProduct(
                    buttonContext,
                    ref,
                    productName: kNetcruxProductName,
                    selection: formalShowInNetCruxSelection(
                      selection.result,
                      designId: _designId(ref),
                    ),
                  ),
                ),
                icon: const Icon(Icons.account_tree_outlined),
                label: Text(l10n.inspectorActionShowInNetcrux),
              ),
            ),
          ),
        // A flow result's hand-off to KLayout, OpenROAD or nextpnr's GUI.
        ...flowHandoffButtons(context, ref, selection),
        // A gate-level result's port waveform, in WaveCrux: a free
        // cross-probe, no badge.
        if (GlsResultView.of(selection.result) != null)
          OutlinedButton.icon(
            key: const ValueKey('inspectorOpenGateLevelWaveform'),
            onPressed: () => Actions.maybeInvoke<SimcruxActionIntent>(
              context,
              const SimcruxActionIntent(SimcruxAction.openGateLevelWaveform),
            ),
            icon: const Icon(Icons.show_chart),
            label: Text(l10n.inspectorActionOpenGateLevelWaveform),
          ),
      ],
    );
  }

  /// Shared-workspace join key: the design_id of the loaded design's INPUT
  /// (`simcrux.yaml`) directory, the same key NetCrux and WaveCrux compute
  /// for the shared design folder, never the VCD's output directory.
  static String? _designId(WidgetRef ref) {
    final config = ref.read(activeConfigProvider);
    return config == null ? null : cxpDesignIdForPath(config.projectFilePath);
  }

  Future<void> _debugInWaveCrux(
    WidgetRef ref,
    BuildContext context, {
    FormalPartitionRow? partition,
  }) async {
    final l10n = L10N.of(context);
    final waveformPath = partition == null
        ? selection.result.waveformPath
        : eqyPartitionTracePath(selection.result, partition);
    final topModule = selection.spec?.top;
    final designId = _designId(ref);
    final dispatcher = ref.read(debugInWaveCruxDispatcherProvider);
    // Awaited: the dispatcher waits for WaveCrux's acknowledgement, which is
    // where a receiver says what it could not do. Reporting "sent" without
    // reading that reply is how a cross-probe becomes a silent no-op.
    final result = await dispatcher.dispatch(
      waveformPath: waveformPath,
      displayName: selection.testId,
      suggestedSignals: deriveSuggestedSignalsFromTopModule(topModule),
      designId: designId,
      topModule: topModule,
      // The CXP stream coordinate: lets a failing bounded proof hand WaveCrux the step the
      // assertion fired at, not just the trace file. Inert for every other
      // kind of row.
      result: selection.result,
      partition: partition,
    );
    if (!context.mounted) return;
    final message = debugInWaveCruxMessage(l10n, result);
    // Only a clean ack is good news. A partly-honoured hand-off is reported
    // like a failure on purpose: the trace opened, but the thing the user
    // asked for — landing on the failure — did not happen, and the message
    // says which half worked.
    if (debugInWaveCruxSucceeded(result)) {
      showCruxInfoSnack(context, message);
    } else {
      showCruxErrorSnack(context, message);
    }
  }

  Future<void> _rerun(
    WidgetRef ref,
    BuildContext context, {
    required bool forceWaveform,
  }) async {
    final spec = selection.spec;
    if (spec == null) return;
    // A gate-level row is one half of a pair: rerunning its gate spec alone
    // would give a testbench verdict with no comparison, so the row says how
    // to rerun it instead.
    if (GlsResultView.of(selection.result) != null) {
      showCruxInfoSnack(context, L10N.of(context).flowGlsRerunHint);
      return;
    }
    // Recorded before the submit rather than after it, because the submit's
    // future only completes when the *whole re-run* has been dispatched, and
    // the question here is "did the user reach for this button", not "did the
    // simulator start". The bool is the whole payload: `waveform_forced`
    // distinguishes the two buttons, and nothing about the test being re-run
    // is anyone's business: telemetry never carries design data.
    ref
        .read(telemetryServiceProvider)
        .record(
          TelemetryEvent(
            'test.rerun',
            properties: <String, Object?>{'waveform_forced': forceWaveform},
          ),
        );
    final adjusted = forceWaveform
        ? spec.copyWith(
            waveform: WaveformPolicy(
              capture: WaveformCapturePolicy.always,
              format: spec.waveform.format,
            ),
          )
        : spec;
    if (ref.read(activeConfigProvider) == null) return;
    // `submitSpecs`, exactly as Re-run Selected Test does. This used to
    // narrow the selected test's suite in a copy of the config and hand it
    // to `start()`, which submits every suite — so the other suites' tests
    // all ran too — and publishes the narrowed copy as the active config,
    // shrinking the next plain Run Regression.
    await ref.read(regressionRunnerProvider.notifier).submitSpecs(<TestSpec>[
      adjusted,
    ], concurrency: 1);
  }

  Future<void> _openSource(WidgetRef ref, BuildContext context) async {
    final spec = selection.spec;
    if (spec == null) return;
    final launcher = ref.read(editorLauncherProvider);
    String sourcePath;
    if (spec.sources.isNotEmpty) {
      // Pick the source whose basename starts with the top module
      // name, falling back to the first source. Verilog convention is
      // that the testbench shares the top module's name.
      final match = spec.sources.firstWhere(
        (s) {
          final base = s.split('/').last.split('.').first;
          return base == spec.top || base == '${spec.top}_tb';
        },
        orElse: () => spec.sources.first,
      );
      sourcePath = match;
    } else {
      return;
    }
    // Record the navigation as an explicit source selection so the
    // CXP notify_selection emitter broadcasts it as an
    // ElementKind.source event. Stays a no-op when CXP is disabled.
    ref.read(explicitSourceSelectionProvider.notifier).select(sourcePath);
    final ok = await launcher.openSource(filePath: sourcePath);
    if (!ok && context.mounted) {
      // A failed hand-off used to be silent, so a wrong or missing editor
      // command looked like a button that did nothing. Name the command the
      // user can fix, not the path.
      final command = launcher.template.trim().split(RegExp(r'\s+')).first;
      showCruxErrorSnack(
        context,
        L10N.of(context).inspectorOpenSourceFailed(command),
      );
    }
    // `ok` is the whole signal: the editor command template is user-authored
    // free text, so the template, the executable it names and the path it
    // opened all stay on the machine. What ships is one bit — did the
    // click-to-source hand-off work — which is exactly the roadmap question
    // ("click-to-source reliability") and nothing more.
    ref
        .read(telemetryServiceProvider)
        .record(
          TelemetryEvent(
            'editor.launched',
            properties: <String, Object?>{'ok': ok},
          ),
        );
  }
}
