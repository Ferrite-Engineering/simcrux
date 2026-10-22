// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:isolate';

import 'package:crux_flow/crux_flow.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show FutureProviderFamily, Override;
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/providers/regression_runner.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/remote/services/flow_path_selection.dart';
import 'package:simcrux/services/flow/flow_run_index.dart';
import 'package:simcrux/services/flow/flow_worst_paths.dart';

/// Runs [task] off the UI isolate. The readers behind the Flow Runs panel
/// read whole report and metrics files, which must never happen on the UI
/// isolate.
typedef FlowBackgroundRunner =
    Future<T> Function<T>(FutureOr<T> Function() task);

/// How the Flow Runs panel runs its readers: [Isolate.run] in the app.
/// Widget tests override it with a direct call.
final Provider<FlowBackgroundRunner> flowBackgroundRunnerProvider =
    Provider<FlowBackgroundRunner>(
      (ref) => _isolateRun,
      name: 'flowBackgroundRunnerProvider',
    );

Future<T> _isolateRun<T>(FutureOr<T> Function() task) => Isolate.run(task);

/// Where zipped artifacts are extracted; SimCrux's own temporary directory
/// when null. Tests point it at a temporary directory of their own.
final Provider<String?> flowArchiveScratchProvider = Provider<String?>(
  (ref) => null,
  name: 'flowArchiveScratchProvider',
);

/// Where gate-level simulation writes its generated port-dump modules and the
/// two port dumps of each test: SimCrux's own scratch, never a run directory
/// or the project. `simcrux_gls` in the system temporary directory when null.
/// Tests point it at a temporary directory of their own.
final Provider<String?> flowGlsScratchProvider = Provider<String?>(
  (ref) => null,
  name: 'flowGlsScratchProvider',
);

/// Whether the Flow Runs panel is shown.
///
/// App-wide and session-only, like the cross-probe panel: one flag for
/// every tab, toggled by View > Flow Runs and the tab's own close button.
final NotifierProvider<FlowRunsVisibilityNotifier, bool>
flowRunsVisibleProvider = NotifierProvider<FlowRunsVisibilityNotifier, bool>(
  FlowRunsVisibilityNotifier.new,
  name: 'flowRunsVisibleProvider',
);

/// Backs [flowRunsVisibleProvider]. Hidden by default.
class FlowRunsVisibilityNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  /// Flips the panel between shown and hidden.
  void toggle() => state = !state;

  /// Shows or hides the panel.
  // ignore: use_setters_to_change_properties
  void set({required bool visible}) => state = visible;
}

/// The project directory of [config]: where its runs and `ingest:` paths
/// are contained.
String flowProjectRoot(RegressionConfig config) =>
    p.dirname(p.normalize(p.absolute(config.projectFilePath)));

/// The paths the user ingested into this tab this session (Ingest Run
/// Directory…, Ingest Zipped Artifact…). Per tab.
final NotifierProvider<FlowIngestedPathsNotifier, List<String>>
flowIngestedPathsProvider =
    NotifierProvider<FlowIngestedPathsNotifier, List<String>>(
      FlowIngestedPathsNotifier.new,
      name: 'flowIngestedPathsProvider',
    );

/// Backs [flowIngestedPathsProvider].
class FlowIngestedPathsNotifier extends Notifier<List<String>> {
  @override
  List<String> build() => const <String>[];

  /// Adds [path], once.
  void add(String path) {
    final normalized = p.normalize(p.absolute(path));
    if (state.contains(normalized)) return;
    state = <String>[...state, normalized];
  }
}

/// Every run the Flow Runs panel lists for the project at [projectRoot]:
/// the runs of the tab's `flow:` entries, its `ingest:` paths and what the
/// user ingested, newest first. Per tab.
///
/// Read off the UI isolate.
final FutureProviderFamily<FlowRunIndex, String> flowRunIndexProvider =
    FutureProvider.family<FlowRunIndex, String>(
      flowRunIndex,
      name: 'flowRunIndexProvider',
    );

/// Body of [flowRunIndexProvider], shared with the per-tab override.
Future<FlowRunIndex> flowRunIndex(Ref ref, String projectRoot) async {
  final config = ref.watch(activeConfigProvider);
  final ingested = ref.watch(flowIngestedPathsProvider);
  final run = ref.watch(flowBackgroundRunnerProvider);
  final scratch = ref.watch(flowArchiveScratchProvider);
  final flow = config?.flow;
  final request = FlowRunIndexRequest(
    projectRoot: projectRoot,
    entries: flow?.entries ?? const [],
    configIngest: flow?.ingest ?? const <String>[],
    userIngest: ingested,
    archiveScratch: scratch,
  );
  if (request.entries.isEmpty &&
      request.configIngest.isEmpty &&
      request.userIngest.isEmpty) {
    return FlowRunIndex.empty;
  }
  return await run(() => buildFlowRunIndex(request));
}

/// The run selected in the Flow Runs panel, or the flow result the
/// inspector handed off: what Open in KLayout, Open in OpenROAD and Open in
/// nextpnr GUI open. Per tab.
@immutable
class FlowRunSelection {
  /// Creates the selection.
  const FlowRunSelection({
    required this.root,
    required this.kind,
    this.design,
  });

  /// The run directory.
  final String root;

  /// Which flow wrote it.
  final FlowKind kind;

  /// The design (the `flow:` entry name) it belongs to, when known.
  final String? design;

  @override
  bool operator ==(Object other) =>
      other is FlowRunSelection &&
      other.root == root &&
      other.kind == kind &&
      other.design == design;

  @override
  int get hashCode => Object.hash(root, kind, design);
}

/// The selected flow run. Per tab.
final NotifierProvider<FlowSelectedRunNotifier, FlowRunSelection?>
flowSelectedRunProvider =
    NotifierProvider<FlowSelectedRunNotifier, FlowRunSelection?>(
      FlowSelectedRunNotifier.new,
      name: 'flowSelectedRunProvider',
    );

/// Backs [flowSelectedRunProvider].
class FlowSelectedRunNotifier extends Notifier<FlowRunSelection?> {
  @override
  FlowRunSelection? build() => null;

  /// Selects [selection].
  // ignore: use_setters_to_change_properties
  void select(FlowRunSelection? selection) => state = selection;
}

/// The worst path the user is on in the Flow Runs panel's paths table, for
/// Cross-probe Selection: set when the table takes focus or moves its
/// current row, and cleared when the run or the selected test changes, so the
/// command sends the path only while the path is what the user last chose.
/// Per tab.
final NotifierProvider<FlowFocusedPathNotifier, FlowPathTarget?>
flowFocusedPathProvider =
    NotifierProvider<FlowFocusedPathNotifier, FlowPathTarget?>(
      FlowFocusedPathNotifier.new,
      name: 'flowFocusedPathProvider',
    );

/// Backs [flowFocusedPathProvider].
class FlowFocusedPathNotifier extends Notifier<FlowPathTarget?> {
  @override
  FlowPathTarget? build() {
    // Listened, not watched: a watch would rebuild (and clear) the state on
    // the very change it is meant to follow, and the listeners close with
    // the provider.
    ref
      ..listen<String?>(selectedTestIdProvider, (previous, next) {
        if (previous != next) state = null;
      })
      ..listen<FlowRunSelection?>(flowSelectedRunProvider, (previous, next) {
        if (previous?.root != next?.root) state = null;
      });
    return null;
  }

  /// Records [target] as the path the user is on.
  // ignore: use_setters_to_change_properties
  void focus(FlowPathTarget target) => state = target;

  /// Forgets it.
  void clear() => state = null;
}

/// The register a peer asked to see the timing paths through (NetCrux's
/// "Show timing paths through this register"): the paths table lists only
/// the paths that start or end at it until the user shows them all. Null
/// when the table is unfiltered. Per tab.
final NotifierProvider<FlowPathRegisterFilterNotifier, String?>
flowPathRegisterFilterProvider =
    NotifierProvider<FlowPathRegisterFilterNotifier, String?>(
      FlowPathRegisterFilterNotifier.new,
      name: 'flowPathRegisterFilterProvider',
    );

/// Backs [flowPathRegisterFilterProvider].
class FlowPathRegisterFilterNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  /// Filters to the paths through [register].
  // ignore: use_setters_to_change_properties
  void set(String register) => state = register;

  /// Shows every path again.
  void clear() => state = null;
}

/// Which run [flowWorstPathsProvider] reads: the run and its design (the
/// `flow:` entry name the run index files it under), null when not known.
typedef FlowWorstPathsRequest = ({FlowRunRef run, String? design});

/// The worst paths of the run [FlowWorstPathsRequest.run] names, each mapped
/// to the RTL, read on a background isolate. Per tab.
final FutureProviderFamily<FlowWorstPaths, FlowWorstPathsRequest>
flowWorstPathsProvider =
    FutureProvider.family<FlowWorstPaths, FlowWorstPathsRequest>(
      flowWorstPaths,
      name: 'flowWorstPathsProvider',
    );

/// Body of [flowWorstPathsProvider], shared with the per-tab override.
///
/// The entry's `netlist:`, when it has one, is the first netlist the mapping
/// looks for.
Future<FlowWorstPaths> flowWorstPaths(Ref ref, FlowWorstPathsRequest request) {
  final run = ref.watch(flowBackgroundRunnerProvider);
  final design = request.design;
  String? netlist;
  if (design != null) {
    final entries = ref.watch(activeConfigProvider)?.flow?.entries;
    for (final entry in entries ?? const <FlowEntry>[]) {
      if (entry.name == design) netlist = entry.netlist;
    }
  }
  return run(() => readFlowWorstPaths(request.run, netlist: netlist));
}

/// Keeps the Flow Runs panel current while the tab's regression runs:
/// re-reads the run index every [kFlowWatchInterval] while a regression is
/// in flight (live step progress from LibreLane's step directories), and
/// once more when it finishes. Per tab.
///
/// **Dependency-free on purpose.** Its `build` watches nothing: a provider
/// that watched the runner would be rebuilt, and its timer cancelled by
/// `onDispose`, at every state change. It listens instead, and the panel
/// keeps it alive by watching it.
final NotifierProvider<FlowRunWatcher, int> flowRunWatcherProvider =
    NotifierProvider<FlowRunWatcher, int>(
      FlowRunWatcher.new,
      name: 'flowRunWatcherProvider',
    );

/// How often the Flow Runs panel re-reads its runs while a regression runs.
const Duration kFlowWatchInterval = Duration(seconds: 3);

/// Backs [flowRunWatcherProvider]. Its state counts the refreshes.
class FlowRunWatcher extends Notifier<int> {
  Timer? _timer;

  @override
  int build() {
    ref
      ..onDispose(_stop)
      ..listen<AsyncValue<RegressionRunState?>>(regressionRunnerProvider, (
        previous,
        next,
      ) {
        final running = _running(next);
        if (running && _timer == null) {
          _timer = Timer.periodic(kFlowWatchInterval, (_) => _refresh());
        } else if (!running && _timer != null) {
          _stop();
          _refresh();
        }
      });
    return 0;
  }

  static bool _running(AsyncValue<RegressionRunState?> run) {
    final value = run.value;
    return value != null && !value.isFinished;
  }

  void _refresh() {
    ref.invalidate(flowRunIndexProvider);
    state = state + 1;
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }
}

/// The Flow per-tab overrides, applied by `simcruxTabOverrides` and by the
/// Pro overlay's per-tab factory, so each tab has its own selection, ingest
/// list, index, paths and watcher.
List<Override> flowTabOverrides() => <Override>[
  flowIngestedPathsProvider.overrideWith(FlowIngestedPathsNotifier.new),
  flowSelectedRunProvider.overrideWith(FlowSelectedRunNotifier.new),
  flowFocusedPathProvider.overrideWith(FlowFocusedPathNotifier.new),
  flowPathRegisterFilterProvider.overrideWith(
    FlowPathRegisterFilterNotifier.new,
  ),
  flowRunWatcherProvider.overrideWith(FlowRunWatcher.new),
  flowRunIndexProvider.overrideWith(flowRunIndex),
  flowWorstPathsProvider.overrideWith(flowWorstPaths),
];
