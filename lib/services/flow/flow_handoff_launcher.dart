// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_flow/crux_flow.dart';
import 'package:crux_io/crux_io.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/core/telemetry/crux_telemetry_headless.dart';
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/domain/models/flow_tool_settings.dart';
import 'package:simcrux/services/flow/flow_process_driver.dart';
import 'package:simcrux/services/flow/flow_toolchain_probe.dart';
import 'package:simcrux/services/flow/nextpnr_flow_driver.dart';

/// A viewer a flow run is handed to.
enum FlowViewer {
  /// KLayout, on the run's final GDS.
  klayout('klayout', FlowTool.klayout),

  /// OpenROAD's GUI, on the run's final database.
  openroadGui('openroad_gui', FlowTool.openroad),

  /// nextpnr's GUI, on the placed and routed netlist.
  nextpnrGui('nextpnr_gui', FlowTool.nextpnrIce40);

  const FlowViewer(this.token, this.tool);

  /// The `flow.handoff.launched.viewer` token and the `handoff:` key.
  final String token;

  /// The tool the viewer is, for the probe's guidance.
  final FlowTool tool;
}

/// What a hand-off did.
@immutable
class FlowHandoffResult {
  /// Creates the result.
  const FlowHandoffResult({
    required this.ok,
    this.argv = const <String>[],
    this.guidance,
    this.missingTool,
  });

  /// Whether the viewer was started.
  final bool ok;

  /// The command line started, or the one that could not be.
  final List<String> argv;

  /// What to do next, when it was not started: the probe's guidance for a
  /// missing viewer, or why the run cannot be opened.
  final String? guidance;

  /// The missing viewer's tool token, when that is why.
  final String? missingTool;
}

/// Starts a process detached from SimCrux: the viewer outlives the app and
/// is never reaped.
typedef FlowDetachedStarter =
    Future<void> Function(
      String executable,
      List<String> args, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

/// Hands a flow run to an external viewer: KLayout, OpenROAD's GUI or
/// nextpnr's GUI.
///
/// Fire-and-forget and detached: the viewer is started with the engine PATH
/// augmentation a GUI app needs (a macOS app opened from Finder does not see
/// the shell's PATH) and never blocks or is reaped by SimCrux. A missing
/// viewer is not an error: the result carries the probe's guidance.
///
/// Every file named is found inside the run root (symlinks resolved); the
/// OpenROAD read script is written to SimCrux's own scratch directory, never
/// into the run. A project's `handoff:` command for a viewer (honoured only
/// under project-tooling consent, which the loader enforced) replaces the
/// default, with `{run_dir}`, `{gds}`, `{odb}` and `{json}` expanded.
class FlowHandoffLauncher {
  /// Creates the launcher.
  FlowHandoffLauncher({
    FlowDetachedStarter? start,
    FlowToolchainProbe? probe,
    this.telemetry,
    this.scratch,
  }) : _start = start ?? _startDetached,
       _probe = probe ?? FlowToolchainProbe();

  final FlowDetachedStarter _start;
  final FlowToolchainProbe _probe;

  /// SimCrux's own scratch directory for generated scripts. When null each
  /// script gets a fresh directory of its own made directly in the system
  /// temporary directory, never under a fixed name there: on a shared Linux
  /// host `/tmp` belongs to every user, and a fixed `/tmp/simcrux` another
  /// user made first would let them rewrite the script OpenROAD runs.
  final Directory? scratch;

  /// Where `flow.handoff.launched` and `flow.tool.missing` go; none in
  /// tests or headless.
  final TelemetryService? telemetry;

  /// Opens [run] (its kind and root) in [viewer].
  ///
  /// [librelanePath] is the Settings path for LibreLane: the executable (or
  /// its directory) for the `path` launcher, the checkout for `nix`.
  Future<FlowHandoffResult> open(
    FlowViewer viewer, {
    required FlowKind kind,
    required String runRoot,
    FlowEntry? entry,
    FlowToolSettings settings = const FlowToolSettings(),
    String? nextpnrPath,
    String? librelanePath,
  }) async {
    final planned = plan(
      viewer,
      kind: kind,
      runRoot: runRoot,
      entry: entry,
      settings: settings,
      nextpnrPath: nextpnrPath,
      librelanePath: librelanePath,
    );
    final argv = planned.argv;
    if (argv == null) {
      _record(viewer, ok: false);
      return FlowHandoffResult(ok: false, guidance: planned.problem);
    }
    try {
      await _start(
        argv.first,
        argv.skip(1).toList(growable: false),
        workingDirectory: runRoot,
        environment: _augmentedEnvironment(),
      );
    } on ProcessException {
      _record(viewer, ok: false, missing: viewer.tool.token);
      return FlowHandoffResult(
        ok: false,
        argv: argv,
        guidance: _probe.guidanceFor(viewer.tool),
        missingTool: viewer.tool.token,
      );
    }
    _record(viewer, ok: true);
    return FlowHandoffResult(ok: true, argv: argv);
  }

  /// The command line [viewer] would start for the run, or why there is
  /// none. Pure apart from listing and writing the OpenROAD read script.
  ///
  /// A LibreLane run opens through LibreLane's own `OpenInKLayout` or
  /// `OpenInOpenROAD` flow when SimCrux knows the run's entry and can start
  /// LibreLane (the `path` or `nix` launcher), because that flow supplies the
  /// PDK's layer properties and the run's own views: started from the run's
  /// newest output state (`--with-initial-state`) under a fresh tag, so the
  /// measured run is never written to, and never with `--overwrite` or
  /// `--last-run`. Otherwise KLayout opens the final GDS directly (with the
  /// run's DRC markers, `-m`, when it has them) and OpenROAD reads the final
  /// database through a generated script.
  @visibleForTesting
  ({List<String>? argv, String? problem}) plan(
    FlowViewer viewer, {
    required FlowKind kind,
    required String runRoot,
    FlowEntry? entry,
    FlowToolSettings settings = const FlowToolSettings(),
    String? nextpnrPath,
    String? librelanePath,
    DateTime? now,
  }) {
    final containment = FlowContainment(<String>[runRoot]);
    String? first(String sub, String ext) {
      final dir = p.join(runRoot, sub);
      try {
        final files = <String>[
          for (final e in Directory(dir).listSync(followLinks: false))
            if (e is File && e.path.endsWith(ext) && containment.allows(e.path))
              e.path,
        ]..sort();
        return files.isEmpty ? null : files.first;
      } on FileSystemException {
        return null;
      }
    }

    final gds = kind == FlowKind.librelane
        ? first(p.join('final', 'gds'), '.gds')
        : null;
    final odb = kind == FlowKind.librelane
        ? first(p.join('final', 'odb'), '.odb')
        : null;
    final post = p.join(runRoot, 'post.json');
    final json = kind == FlowKind.nextpnr && containment.allows(post)
        ? (File(post).existsSync() ? post : null)
        : null;

    final custom = entry?.handoff[viewer.token];
    if (custom != null && custom.isNotEmpty) {
      final values = <String, String>{
        'run_dir': runRoot,
        'gds': gds ?? '',
        'odb': odb ?? '',
        'json': json ?? '',
      };
      return (
        argv: <String>[
          for (final arg in custom)
            arg.replaceAllMapped(
              RegExp(r'\{(run_dir|gds|odb|json)\}'),
              (m) => values[m.group(1)!]!,
            ),
        ],
        problem: null,
      );
    }

    if (kind == FlowKind.librelane && viewer != FlowViewer.nextpnrGui) {
      final own = librelaneOwnFlow(
        viewer,
        runRoot: runRoot,
        entry: entry,
        settings: settings,
        librelanePath: librelanePath,
        now: now ?? DateTime.now(),
      );
      if (own != null) return (argv: own, problem: null);
    }

    switch (viewer) {
      case FlowViewer.klayout:
        if (gds == null) {
          return (argv: null, problem: 'the run has no final GDS to open');
        }
        final klayout = settings.klayoutPath.isEmpty
            ? 'klayout'
            : settings.klayoutPath;
        final markers = kind == FlowKind.librelane
            ? _drcMarkers(runRoot, containment)
            : null;
        return (
          argv: <String>[
            klayout,
            gds,
            if (markers != null) ...['-m', markers],
          ],
          problem: null,
        );
      case FlowViewer.openroadGui:
        if (odb == null) {
          return (argv: null, problem: 'the run has no final database to open');
        }
        final script = _writeReadScript(odb);
        if (script == null) {
          return (
            argv: null,
            problem: 'the OpenROAD read script could not be written',
          );
        }
        final openroad = settings.openroadPath.isEmpty
            ? 'openroad'
            : settings.openroadPath;
        return (argv: <String>[openroad, '-gui', script], problem: null);
      case FlowViewer.nextpnrGui:
        final family = entry?.family;
        if (json == null || entry == null || family == null) {
          return (
            argv: null,
            problem:
                'the nextpnr GUI needs the placed netlist (post.json) and the '
                "entry's device",
          );
        }
        final binary = nextpnrPath == null || nextpnrPath.isEmpty
            ? family.binary
            : (Directory(nextpnrPath).existsSync()
                  ? p.join(nextpnrPath, family.binary)
                  : nextpnrPath);
        final device = NextpnrFlowDriver.nextpnrArgs(
          entry,
          NextpnrJob(runDir: runRoot, tag: p.basename(runRoot)),
        ).takeWhile((a) => a != '--json');
        return (
          argv: <String>[binary, '--gui', ...device, '--json', json],
          problem: null,
        );
    }
  }

  /// LibreLane's own open flow for [viewer] on the run at [runRoot], or null
  /// when it cannot be used: no entry with a configuration, a run that is
  /// not under that configuration's `runs/`, no step with output state, the
  /// `docker` launcher (no display from a container), or a `nix` launcher
  /// without a checkout.
  @visibleForTesting
  List<String>? librelaneOwnFlow(
    FlowViewer viewer, {
    required String runRoot,
    required DateTime now,
    FlowEntry? entry,
    FlowToolSettings settings = const FlowToolSettings(),
    String? librelanePath,
  }) {
    final config = entry?.config;
    if (entry == null || config == null) return null;
    final project = entry.projectRoot;
    final configPath = p.isAbsolute(config)
        ? config
        : (project == null ? null : p.join(project, config));
    if (configPath == null || !File(configPath).existsSync()) return null;
    final runs = p.join(p.dirname(configPath), 'runs');
    if (!p.equals(p.dirname(runRoot), runs)) return null;
    final state = _newestState(runRoot);
    if (state == null) return null;
    final tag = FlowProcessDriver.freshTag(runs, 'simcrux-view', now);
    if (tag == null) return null;
    final flow = switch (viewer) {
      FlowViewer.klayout => 'OpenInKLayout',
      FlowViewer.openroadGui => 'OpenInOpenROAD',
      FlowViewer.nextpnrGui => null,
    };
    if (flow == null) return null;
    final args = <String>[
      '--flow',
      flow,
      '--with-initial-state',
      state,
      '--run-tag',
      tag,
      if (settings.pdkRoot.isNotEmpty) ...['--pdk-root', settings.pdkRoot],
      if (entry.pdk != null) ...['--pdk', entry.pdk!],
      configPath,
    ];
    final custom = librelanePath ?? '';
    switch (entry.launcher ?? settings.launcher) {
      case FlowLauncher.path:
        final binary =
            entry.librelaneBinary ??
            (custom.isEmpty
                ? 'librelane'
                : (Directory(custom).existsSync()
                      ? p.join(custom, 'librelane')
                      : custom));
        return <String>[binary, ...args];
      case FlowLauncher.nix:
        if (custom.isEmpty || !Directory(custom).existsSync()) return null;
        return <String>[
          'nix',
          'develop',
          custom,
          '--command',
          'librelane',
          ...args,
        ];
      case FlowLauncher.docker:
        return null;
    }
  }

  /// The newest step's `state_out.json` under [runRoot], inside it.
  static String? _newestState(String runRoot) {
    final containment = FlowContainment(<String>[runRoot]);
    final steps = <(int, String)>[];
    try {
      for (final e in Directory(runRoot).listSync(followLinks: false)) {
        if (e is! Directory) continue;
        final m = kLibreLaneStepDirectory.firstMatch(p.basename(e.path));
        if (m == null) continue;
        steps.add((int.tryParse(m.group(1)!) ?? -1, e.path));
      }
    } on FileSystemException {
      return null;
    }
    steps.sort((a, b) => b.$1.compareTo(a.$1));
    for (final (_, dir) in steps) {
      final state = p.join(dir, 'state_out.json');
      if (File(state).existsSync() && containment.allows(state)) {
        return containment.require(state);
      }
    }
    return null;
  }

  /// The run's KLayout DRC markers, else its Magic ones, when it has them.
  static String? _drcMarkers(String runRoot, FlowContainment containment) {
    for (final (slug, file) in const <(String, String)>[
      ('klayout-drc', 'drc.klayout.lyrdb'),
      ('magic-drc', 'drc.magic.lyrdb'),
    ]) {
      try {
        final dirs = <String>[
          for (final e in Directory(runRoot).listSync(followLinks: false))
            if (e is Directory &&
                kLibreLaneStepDirectory.hasMatch(p.basename(e.path)) &&
                p.basename(e.path).endsWith('-$slug'))
              e.path,
        ]..sort();
        for (final dir in dirs.reversed) {
          final markers = p.join(dir, 'reports', file);
          if (File(markers).existsSync() && containment.allows(markers)) {
            return containment.require(markers);
          }
        }
      } on FileSystemException {
        return null;
      }
    }
    return null;
  }

  /// Writes `read_db <odb>` to a fresh file in SimCrux's scratch directory.
  ///
  /// The directory is made by `createTempSync` (a new, unpredictable name,
  /// readable by its owner only on POSIX) directly in [scratch] or the system
  /// temporary directory, so no other user can have made it or a parent of it.
  @visibleForTesting
  String? writeReadScript(String odb) => _writeReadScript(odb);

  String? _writeReadScript(String odb) {
    try {
      final custom = scratch?..createSync(recursive: true);
      final dir = custom != null
          ? custom.createTempSync('handoff_')
          : Directory.systemTemp.createTempSync('simcrux_handoff_');
      final script = File(p.join(dir.path, 'open.tcl'))
        ..writeAsStringSync('read_db {${odb.replaceAll('}', r'\}')}}\n');
      return script.path;
    } on FileSystemException {
      return null;
    }
  }

  void _record(FlowViewer viewer, {required bool ok, String? missing}) {
    final service = telemetry;
    if (service == null) return;
    service.record(
      TelemetryEvent(
        'flow.handoff.launched',
        properties: <String, Object?>{'viewer': viewer.token, 'ok': ok},
      ),
    );
    if (missing != null) {
      service.record(
        TelemetryEvent(
          'flow.tool.missing',
          properties: <String, Object?>{'tool': missing},
        ),
      );
    }
  }

  static Map<String, String>? _augmentedEnvironment() {
    final dirs = engineSearchDirs();
    if (dirs.isEmpty) return null;
    final augmented = appendMissingPathDirs(
      Platform.environment['PATH'] ?? '',
      dirs,
      separator: Platform.isWindows ? ';' : ':',
      caseInsensitive: Platform.isWindows,
    );
    return augmented == null ? null : <String, String>{'PATH': augmented};
  }

  /// Detached by design: a viewer is the user's window and outlives the
  /// run, so it is neither reaped nor waited on.
  static Future<void> _startDetached(
    String executable,
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    final resolved = SpawnHost.current().requireExecutable(
      executable,
      childEnvironment: environment,
    );
    await Process.start(
      resolved,
      args,
      workingDirectory: workingDirectory,
      environment: environment,
      mode: ProcessStartMode.detached,
    );
  }
}
