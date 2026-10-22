// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:crux_flow/crux_flow.dart'
    show FlowContainment, FlowContainmentException;
import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:crux_workspace/crux_workspace.dart' show WorkspaceTab;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/formal_config.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/flow/flow_actions.dart';
import 'package:simcrux/features/flow/providers/flow_providers.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/inspector/services/editor_launcher_provider.dart';
import 'package:simcrux/features/remote/providers/notify_selection_emitter.dart';
import 'package:simcrux/features/remote/services/cxp_workspace_link.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/active_tab_container.dart';
import 'package:simcrux/features/workspace/providers/container_managers.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/services/crux_project_resolution.dart';
import 'package:simcrux/services/flow/flow_run_index.dart';
import 'package:simcrux/services/remote/cxp/cxp_project_open_handle.dart';

/// "Anchor" provider that publishes the project opener a
/// `request_open_artifact` for a SimCrux project goes through
/// ([openCxpConfigTab]) into the services-layer [CxpProjectOpenHandle].
///
/// SimCrux's tabs are root-scoped, so opening one needs the workspace notifier
/// and no widget, and this provider lives as long as the app does. Watch it
/// from the app root. An opener already published, a test's, is left in
/// place.
final Provider<void> cxpProjectOpenerPublisherProvider = Provider<void>((ref) {
  final handle = ref.read(cxpProjectOpenHandleProvider);
  if (handle.opener != null) return;
  Future<bool> opener(String configPath) => openCxpConfigTab(ref, configPath);
  handle.opener = opener;
  // `ref` may not be used in `onDispose`, so the withdrawal holds the handle
  // and the opener it published, and clears its own and nobody else's.
  ref.onDispose(() {
    if (identical(handle.opener, opener)) handle.opener = null;
  });
});

/// Handles inbound `request_highlight`, `request_open_source` and
/// `request_open_artifact` messages by dispatching them to SimCrux's
/// selection providers, dashboard filter, and editor launcher.
///
/// The handler is intentionally thin: every effect goes through an
/// existing per-feature provider so the inbound code path matches the
/// internal code path. The notify_selection emitter then observes the
/// resulting state change and re-broadcasts, completing the round-trip
/// for symmetric peers.
///
/// The shared runtime acknowledges every request from the result a method
/// returns and asks for the user's attention when one was honoured, so this
/// class never replies on the wire and never bounces the dock.
///
/// **Active-tab routing.** `selectedTestIdProvider`,
/// `dashboardFilterProvider`, and `activeConfigProvider` are per-tab
/// (open-core mode) or tab-project-scoped (Pro mode); this handler is
/// root-hosted. Every read/write therefore resolves the ACTIVE tab's
/// container via [activeTabContainerOf] first: writing the root
/// instances would be a silent no-op while the ack still claimed
/// `honored: true`. The direct root-`ref` fallback applies only when
/// no workspace is mounted (headless tests, pre-hydration startup).
class SimcruxCxpRequestHandler extends CruxCxpRequestHandler {
  /// Constructs a handler bound to [ref].
  SimcruxCxpRequestHandler(this.ref);

  /// Riverpod ref used for reads + writes.
  final Ref ref;

  /// Handles an inbound `request_highlight`: applies it locally, and when that
  /// misses falls back to the shared workspace: reads
  /// `crux.design_id` from the message metadata, resolves the design's `source`
  /// artifact, and opens it in the editor.
  @override
  Future<CruxCxpHandlerResult> highlight(
    RequestHighlight request,
    PeerIdentity from,
  ) async {
    var result = _handleRequestHighlight(request);
    if (!result.honored) {
      final opened = await _openDesignSourceFromWorkspace(request.metadata);
      if (opened) {
        result = const CruxCxpHandlerResult(
          honored: true,
          reason: 'opened design source from the shared workspace',
        );
      }
    }
    // Both outcomes are recorded, and that is the point of the `honored`
    // property: a cross-probe a peer sent and this app could not act on is the
    // failure mode the suite network-effect funnel exists to surface, so
    // dropping it would leave the metric reading healthy exactly when it is
    // not. Nothing about the element, the sender or the ack's `reason` string
    // travels: one direction token and one bool.
    ref
        .read(telemetryServiceProvider)
        .record(
          TelemetryEvent(
            'cxp.crossprobe',
            properties: <String, Object?>{
              'direction': 'inbound',
              'honored': result.honored,
            },
          ),
        );
    return result;
  }

  /// Handles an inbound `request_open_artifact`. SimCrux opens three kinds
  /// (CXP §9.10.2):
  ///
  /// * `project`: its own project (a `simcrux.yaml`, or a
  ///   `<design>.crux-project` naming one) as a config tab
  ///   ([_openProjectForPeer]);
  /// * `source`: a project the same way, for peers that published one under
  ///   the old kind, and any HDL file in the user's editor
  ///   ([_openSourceInEditor]);
  /// * `flow_run`: the implementation run it holds for the design, shown in
  ///   that project's Flow Runs panel ([_openFlowRun]).
  ///
  /// The file is resolved through the shared workspace store first, the
  /// sender's hint path only after it, whose absolute path may not exist on
  /// this machine's layout. Not honoured, with a reason that never repeats the
  /// sender's path, design id or kind (CXP §9.11), when the kind is another
  /// one, nothing is recorded or hinted, the path is refused, or the open
  /// fails.
  @override
  Future<CruxCxpHandlerResult> openArtifact(
    RequestOpenArtifact request,
    PeerIdentity from,
  ) async {
    switch (request.artifactKind) {
      case kCxpFlowRunArtifactKind:
        return await _openFlowRun(request);
      case kCxpProjectArtifactKind:
        return await _openProjectArtifact(request);
      case kCxpSourceArtifactKind:
        break;
      default:
        // A known kind SimCrux does not open (`waveform`, `netlist`,
        // `timing_report`) or one it has never heard of: the runtime's own
        // answer for anything a product does not handle.
        return CruxCxpHandlerResult.unsupported;
    }
    // Read under the floor: the rooted store drops the record for a project
    // never opened here, the one "Open in SimCrux Desktop" publishes before
    // it sends. It is only a candidate; which rule it then answers to
    // depends on what it names.
    final path =
        await resolveOpenArtifactSourcePath(ref, request.designId) ??
        request.path;
    if (path == null) {
      return const CruxCxpHandlerResult(
        honored: false,
        reason: 'no source artifact recorded for that design',
      );
    }
    // CXP §11's MUST: the same scrutiny as a `file_path` on the wire, on the
    // value about to be opened. That value came either from our own records
    // (selected by a `design_id` the sender chose, in a user-writable
    // directory) or from the sender's hint, so neither is a provenance. The
    // floor applies whichever way the path goes next, on the exact string;
    // the reason travels back in the ack and never repeats the path
    // (CXP §9.11).
    final refusal = kCxpOpenArtifactContainment.refuse(path);
    if (refusal != null) {
      return CruxCxpHandlerResult(honored: false, reason: refusal);
    }
    return await (isSimcruxProjectPath(path)
        ? _openProjectForPeer(path)
        : _openSourceInEditor(path));
  }

  /// A `project` artifact: the SimCrux project recorded for the design
  /// (`project` records first, then a project file a peer still publishes as
  /// `source`), else the hint, opened as a config tab under the floor. A file
  /// that is not a SimCrux project is answered `honored: false`: several
  /// products publish `project` for one design, and only the format says
  /// whose it is (CXP §9.10.2).
  Future<CruxCxpHandlerResult> _openProjectArtifact(
    RequestOpenArtifact request,
  ) async {
    final path =
        await resolveOpenArtifactProjectPath(ref, request.designId) ??
        request.path;
    if (path == null) {
      return const CruxCxpHandlerResult(
        honored: false,
        reason: 'no project is recorded for that design',
      );
    }
    final refusal = kCxpOpenArtifactContainment.refuse(path);
    if (refusal != null) {
      return CruxCxpHandlerResult(honored: false, reason: refusal);
    }
    if (!isSimcruxProjectPath(path)) {
      return const CruxCxpHandlerResult(
        honored: false,
        reason: 'the project is not one SimCrux reads',
      );
    }
    return await _openProjectForPeer(path);
  }

  /// A `flow_run` artifact (CXP §9.10.2): the implementation run SimCrux
  /// holds for the design, shown in its project's Flow Runs panel.
  ///
  /// The design is matched against the open project tabs by the same
  /// `crux.design_id` SimCrux attaches to what it sends. The run is the one
  /// the hint names when it is one of that project's runs, else the run
  /// selected in its panel, else its newest. A hint naming anything else is
  /// discarded, as §9.10 says, never opened. The run directory is held to
  /// the project directory (symlinks resolved) and to the floor before the
  /// tab is brought forward; nothing is deleted or written.
  Future<CruxCxpHandlerResult> _openFlowRun(RequestOpenArtifact request) async {
    final workspace = ref.read(workspaceProvider).value;
    final WorkspaceContainerManagers managers;
    try {
      managers = ref.read(workspaceContainerManagersProvider);
    } on Object {
      return _noFlowRun;
    }
    final hint = request.path;
    for (final tab
        in workspace?.tabs ?? const <WorkspaceTab<SimcruxTabPayload>>[]) {
      final configPath = tab.payload.configPath;
      if (configPath.isEmpty ||
          cxpDesignIdForPath(configPath) != request.designId) {
        continue;
      }
      final container = managers.tabs.containerFor(tab.id);
      final config = container.read(activeConfigProvider);
      if (config == null) continue;
      final root = flowProjectRoot(config);
      final FlowRunIndex index;
      try {
        index = await container.read(flowRunIndexProvider(root).future);
      } on Object {
        continue;
      }
      if (index.runs.isEmpty) continue;
      final hinted = hint == null
          ? null
          : index.runs.where((r) => p.equals(r.root, hint)).firstOrNull;
      final run =
          hinted ??
          index.byRoot(container.read(flowSelectedRunProvider)?.root) ??
          index.runs.first;
      final refusal = kCxpOpenArtifactContainment.refuse(run.root);
      if (refusal != null) {
        return CruxCxpHandlerResult(honored: false, reason: refusal);
      }
      try {
        FlowContainment(<String>[root]).require(run.root);
      } on FlowContainmentException {
        return const CruxCxpHandlerResult(
          honored: false,
          reason: 'the run is outside its project directory',
        );
      }
      await ref.read(workspaceProvider.notifier).setActiveTab(tab.id);
      container
          .read(flowSelectedRunProvider.notifier)
          .select(
            FlowRunSelection(
              root: run.root,
              kind: run.reading.run.ref.kind,
              design: run.design,
            ),
          );
      FlowActions.revealFlowRuns(ref.read);
      return CruxCxpHandlerResult.ok;
    }
    return _noFlowRun;
  }

  static const CruxCxpHandlerResult _noFlowRun = CruxCxpHandlerResult(
    honored: false,
    reason: 'no implementation run is held for that design',
  );

  /// Opens the file a peer named in an editor, under the rooted rule.
  @override
  Future<CruxCxpHandlerResult> openSource(
    RequestOpenSource request,
    PeerIdentity from,
  ) async {
    // The last gate before a peer's string becomes an editor argv, and the
    // one that keeps it to the directories the user has opened:
    // `LocalCxpServer` screens the wire with the floor only, because its one
    // rule also screens a `request_open_artifact` hint, which must not be
    // rooted (`kCxpOpenArtifactContainment`). A path outside the directories
    // the user has opened is refused here even when it is perfectly absolute
    // (CXP §11), and the reason never repeats it.
    final refusal = ref
        .read(cxpPathContainmentProvider)
        .refuse(request.filePath);
    if (refusal != null) {
      return CruxCxpHandlerResult(honored: false, reason: refusal);
    }
    final launcher = ref.read(editorLauncherProvider);
    final column = request.column ?? 1;
    final ok = await launcher.openSource(
      filePath: request.filePath,
      line: request.line,
      column: column,
    );
    if (ok) return CruxCxpHandlerResult.ok;
    return const CruxCxpHandlerResult(
      honored: false,
      reason: 'editor command malformed or failed to launch',
    );
  }

  /// Opens the SimCrux project at [path] as a config tab, through the
  /// services-layer [CxpProjectOpenHandle]: the answer VS Code's "Open in
  /// SimCrux Desktop" asks for. It used to go to the editor launcher like any
  /// other `source` path, so the YAML came back to VS Code as text while the
  /// ack said it was honoured.
  ///
  /// Held to the floor, which [path] has passed, and not to the directories
  /// the user has opened: `kCxpOpenArtifactContainment` says why a project
  /// open may be, and why an editor launch may not.
  ///
  /// A `<design>.crux-project` is swapped here for the config it names, and
  /// the floor judges the swapped path too, so the string checked is the
  /// string opened (CXP §11.3); the opener swaps nothing.
  Future<CruxCxpHandlerResult> _openProjectForPeer(String path) async {
    // A hint can name the sender's path on its own machine layout, or a
    // config since deleted; a tab for it would hold nothing but an error.
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.file) {
      return const CruxCxpHandlerResult(
        honored: false,
        reason: 'the artifact is not a file here',
      );
    }
    final String config;
    switch (const CruxProjectResolver().resolve(path)) {
      case NotAManifest():
        config = path;
      case ManifestSimulation(:final configPath):
        config = configPath;
      case ManifestAmbiguous():
        return const CruxCxpHandlerResult(
          honored: false,
          reason: 'the design directory holds more than one manifest',
        );
      case ManifestUnusable():
        return const CruxCxpHandlerResult(
          honored: false,
          reason: 'the design manifest names no SimCrux config that is here',
        );
    }
    // The floor again, on the swapped path. The manifest planner today only
    // yields absolute, trimmed paths, so this cannot refuse one; it is here
    // so the string opened is a string checked if the planner ever changes.
    if (config != path) {
      final refusal = kCxpOpenArtifactContainment.refuse(config);
      if (refusal != null) {
        return CruxCxpHandlerResult(honored: false, reason: refusal);
      }
    }
    // What a config tab holds. A manifest that names another manifest, or a
    // directory, is not opened as though it were a config.
    if (!isSimcruxConfigPath(config)) {
      return const CruxCxpHandlerResult(
        honored: false,
        reason: 'the design manifest does not name a SimCrux config',
      );
    }
    final opened = await ref.read(cxpProjectOpenHandleProvider).open(config);
    return opened
        ? CruxCxpHandlerResult.ok
        : const CruxCxpHandlerResult(
            honored: false,
            reason: 'SimCrux could not open the project',
          );
  }

  /// Opens a `source` artifact that is not a SimCrux project in the user's
  /// editor: the gate an editor launch has always had, unchanged: the
  /// rooted rule, the directories the user has opened, on the value about to
  /// become an argv element, and `EditorLauncher`'s substitution into a
  /// single element of the template the user set. `kCxpOpenArtifactContainment`
  /// says why the floor a project open is held to is not enough here.
  Future<CruxCxpHandlerResult> _openSourceInEditor(String path) async {
    final refusal = ref.read(cxpPathContainmentProvider).refuse(path);
    if (refusal != null) {
      return CruxCxpHandlerResult(honored: false, reason: refusal);
    }
    final launcher = ref.read(editorLauncherProvider);
    final ok = await launcher.openSource(filePath: path);
    if (ok) return CruxCxpHandlerResult.ok;
    return const CruxCxpHandlerResult(
      honored: false,
      reason: 'editor command malformed or failed to launch',
    );
  }

  /// Shared-workspace fallback: resolves `crux.design_id` from [metadata] against
  /// the shared workspace and, if a `source` artifact is recorded for that
  /// design, opens it. Returns whether one was opened. The join is
  /// one-directional: the consumer trusts the sender's `crux.design_id` and
  /// never re-derives an id from the file it opens.
  ///
  /// A recorded SimCrux project (`simcrux.yaml`, `.yml`, `.crux-project`)
  /// opens as a config tab through the same bridge `request_open_artifact`
  /// uses; it used to go to the external editor like any other `source`
  /// record, so the YAML opened as text in the user's editor instead of in
  /// SimCrux. Everything else still goes to the editor. The containment
  /// check on the recorded path stays in front of both routes.
  Future<bool> _openDesignSourceFromWorkspace(
    Map<String, Object?> metadata,
  ) async {
    final designId = metadata[cxpDesignIdMetadataKey];
    if (designId is! String || designId.isEmpty) return false;
    final path = await resolveSourceArtifactPath(ref, designId);
    if (path == null) return false;
    // CXP §11: the record was selected by the sender's `design_id`, so the
    // path gets the wire rule on the value about to be opened.
    if (!ref.read(cxpPathContainmentProvider).allows(path)) return false;
    if (isSimcruxProjectPath(path)) {
      return (await _openProjectForPeer(path)).honored;
    }
    final launcher = ref.read(editorLauncherProvider);
    return await launcher.openSource(filePath: path);
  }

  /// Reads provider [provider] from the active tab's container when
  /// one is mounted, falling back to the root scope otherwise.
  T _readScoped<T>(ProviderListenable<T> provider) {
    final tab = activeTabContainerOf(ref);
    if (tab != null) return tab.read(provider);
    return ref.read(provider);
  }

  /// Whether [testId] names a test of the active tab's loaded
  /// [RegressionConfig]. False when no config is loaded: an unloaded
  /// project has no test inventory to select against, so the honest
  /// ack for any test id is `honored: false`.
  bool _testExists(String testId) {
    final config = _readScoped<RegressionConfig?>(activeConfigProvider);
    if (config == null) return false;
    for (final suite in config.suites) {
      for (final test in suite.tests) {
        if (test.id == testId) return true;
      }
    }
    return false;
  }

  CruxCxpHandlerResult _handleRequestHighlight(RequestHighlight msg) {
    final element = msg.element;
    switch (element.kind.known) {
      case KnownElementKind.property:
      case KnownElementKind.timingPath:
      case KnownElementKind.cell:
      case null:
        // [ElementKind] is an open wire type: a peer on a later
        // protocol revision may send a kind this build does not model.
        // Forward-compatible default: ignore it gracefully with an
        // honest `honored: false`, never throw. Crashing the inbound
        // dispatch on an unrecognised kind would defeat the whole point
        // of the type being open.
        return const CruxCxpHandlerResult(
          honored: false,
          reason: 'unsupported element kind',
        );

      case KnownElementKind.test:
        // Honest ack: only claim `honored` when the named test exists
        // in the active tab's loaded config AND the selection lands in
        // the active tab's scope. Selecting a nonexistent id would
        // leave the inspector empty while telling the peer it worked.
        if (!_testExists(element.path)) {
          return const CruxCxpHandlerResult(
            honored: false,
            reason: 'test not found in the active project',
          );
        }
        _readScoped(selectedTestIdProvider.notifier).select(element.path);
        return CruxCxpHandlerResult.ok;

      case KnownElementKind.source:
        // Same vocabulary trick as the originator side: if the path
        // looks like a waveform, SimCrux doesn't host a waveform
        // viewer, so reply with a graceful "not supported here".
        // Otherwise treat as a source file the user wants to look at:
        // record an explicit source selection so the inspector can
        // surface it (and the notify_selection emitter re-broadcasts).
        // Root-scoped on purpose: explicitSourceSelectionProvider is
        // app-global in both open-core and Pro modes.
        ref.read(explicitSourceSelectionProvider.notifier).select(element.path);
        return CruxCxpHandlerResult.ok;

      case KnownElementKind.signal:
      case KnownElementKind.net:
      case KnownElementKind.port:
        // A signal of this design (the sender says which design with
        // `crux.design_id`) filters what SimCrux knows reads it: the formal
        // properties, and the worst paths through the register.
        if (_applyReceiveFilters(element.path, msg.metadata)) {
          return CruxCxpHandlerResult.ok;
        }
        // Otherwise filter the results table to tests whose name substring
        // matches the leaf identifier: SimCrux keeps no signal-to-test
        // index for simulation, and the substring is the cheap
        // approximation.
        final leaf = _leafOf(element.path);
        _readScoped(
          dashboardFilterProvider.notifier,
        ).setTestNameSubstring(leaf);
        return CruxCxpHandlerResult.ok;

      case KnownElementKind.instance:
      case KnownElementKind.scope:
        // Filter to tests whose name substring matches the instance /
        // scope leaf identifier, the same approximation as above. The
        // instance segment of a hierarchical name is the most likely
        // match against a SimCrux test name (typical convention:
        // tb_<module> for unit tests).
        final leaf = _leafOf(element.path);
        _readScoped(
          dashboardFilterProvider.notifier,
        ).setTestNameSubstring(leaf);
        return CruxCxpHandlerResult.ok;

      case KnownElementKind.breakpoint:
        // SimCrux does not yet expose a breakpoint editor surface;
        // the breakpoint mapping is reserved by the resolver so the
        // wire-up is one line when the editor lands. Graceful no.
        return const CruxCxpHandlerResult(
          honored: false,
          reason: 'breakpoint editor not yet implemented in this build',
        );

      case KnownElementKind.marker:
      case KnownElementKind.rule:
        // SimCrux is not the natural owner of waveform markers
        // (WaveCrux) or rule sites (LintCrux). Decline politely.
        return const CruxCxpHandlerResult(
          honored: false,
          reason: 'simcrux does not own marker or rule elements',
        );
    }
  }

  /// The receive filters for a signal a peer named with its design's
  /// `crux.design_id` (free on every tier): the results table to the formal
  /// rows with a property that reads it, when the project has formal tests,
  /// and the Flow Runs panel's worst paths to the paths that start or end at
  /// that register, when the project has a `flow:` block (the panel is shown
  /// on its paths). Returns whether either applied; neither applies to a
  /// signal sent without a design.
  bool _applyReceiveFilters(String signal, Map<String, Object?> metadata) {
    final designId = metadata[cxpDesignIdMetadataKey];
    if (designId is! String || designId.isEmpty) return false;
    final config = _readScoped<RegressionConfig?>(activeConfigProvider);
    if (config == null) return false;
    var applied = false;
    // `sby` rows are the ones whose properties record what they read.
    final formal = config.suites.any(
      (suite) =>
          suite.tests.any((t) => t.simulatorId == FormalConfig.kSbySimulatorId),
    );
    if (formal) {
      _readScoped(dashboardFilterProvider.notifier).setFormalReads(signal);
      applied = true;
    }
    if (config.flow != null) {
      _readScoped(flowPathRegisterFilterProvider.notifier).set(signal);
      FlowActions.revealFlowRuns(ref.read);
      applied = true;
    }
    return applied;
  }

  String _leafOf(String hierarchicalPath) {
    if (hierarchicalPath.isEmpty) return hierarchicalPath;
    // Strip optional [range] bit slice off the right.
    var p = hierarchicalPath;
    final bracket = p.indexOf('[');
    if (bracket > 0) p = p.substring(0, bracket);
    final lastDot = p.lastIndexOf('.');
    if (lastDot < 0) return p;
    return p.substring(lastDot + 1);
  }
}
