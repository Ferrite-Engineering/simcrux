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

  /// SimCrux's own scratch directory for generated scripts; the system
  /// temporary directory's `simcrux/` when null.
  final Directory? scratch;

  /// Where `flow.handoff.launched` and `flow.tool.missing` go; none in
  /// tests or headless.
  final TelemetryService? telemetry;

  /// Opens [run] (its kind and root) in [viewer].
  Future<FlowHandoffResult> open(
    FlowViewer viewer, {
    required FlowKind kind,
    required String runRoot,
    FlowEntry? entry,
    FlowToolSettings settings = const FlowToolSettings(),
    String? nextpnrPath,
  }) async {
    final planned = plan(
      viewer,
      kind: kind,
      runRoot: runRoot,
      entry: entry,
      settings: settings,
      nextpnrPath: nextpnrPath,
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
  @visibleForTesting
  ({List<String>? argv, String? problem}) plan(
    FlowViewer viewer, {
    required FlowKind kind,
    required String runRoot,
    FlowEntry? entry,
    FlowToolSettings settings = const FlowToolSettings(),
    String? nextpnrPath,
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

    switch (viewer) {
      case FlowViewer.klayout:
        if (gds == null) {
          return (argv: null, problem: 'the run has no final GDS to open');
        }
        final klayout = settings.klayoutPath.isEmpty
            ? 'klayout'
            : settings.klayoutPath;
        return (argv: <String>[klayout, gds], problem: null);
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

  /// Writes `read_db <odb>` to a fresh file in SimCrux's scratch directory.
  String? _writeReadScript(String odb) {
    try {
      final base =
          scratch ?? Directory(p.join(Directory.systemTemp.path, 'simcrux'))
            ..createSync(recursive: true);
      final dir = base.createTempSync('handoff_');
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
