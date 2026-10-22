// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:crux_io/crux_io.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/riscv_host_platform.dart';
import 'package:simcrux/domain/models/flow_tool_settings.dart';
import 'package:simcrux/services/job_scheduler/process_reaper.dart';

/// One tool the implementation flows use.
enum FlowTool {
  /// LibreLane, through the `path` launcher.
  librelane('librelane', 'librelane', <String>['--version']),

  /// Nix, for the `nix` launcher.
  nix('nix', 'nix', <String>['--version']),

  /// Docker, for the `docker` launcher.
  docker('docker', 'docker', <String>['--version']),

  /// OpenROAD, for the hand-off.
  openroad('openroad', 'openroad', <String>['-version']),

  /// Yosys, for nextpnr synthesis.
  yosys('yosys', 'yosys', <String>['-V']),

  /// nextpnr for iCE40.
  nextpnrIce40('nextpnr', 'nextpnr-ice40', <String>['--version']),

  /// nextpnr for ECP5.
  nextpnrEcp5('nextpnr', 'nextpnr-ecp5', <String>['--version']),

  /// nextpnr himbaechel (Gowin, GateMate).
  nextpnrHimbaechel('nextpnr', 'nextpnr-himbaechel', <String>['--version']),

  /// KLayout, for the hand-off.
  klayout('klayout', 'klayout', <String>['-v']),

  /// FuseSoC, for FuseSoC entries.
  fusesoc('fusesoc', 'fusesoc', <String>['--version']);

  const FlowTool(this.token, this.binaryName, this.versionArgs);

  /// The `flow.tool.missing.tool` token.
  final String token;

  /// The executable name looked up.
  final String binaryName;

  /// The arguments that print its version.
  final List<String> versionArgs;
}

/// What the probe found for one [FlowTool].
@immutable
class FlowToolReport {
  /// Creates the row.
  const FlowToolReport({
    required this.tool,
    required this.binary,
    required this.found,
    this.version,
  });

  /// The tool.
  final FlowTool tool;

  /// The executable that was asked.
  final String binary;

  /// Whether it answered.
  final bool found;

  /// The first line it printed, when it answered.
  final String? version;
}

/// What the probe found.
@immutable
class FlowToolchainReport {
  /// Creates the report.
  const FlowToolchainReport({
    required this.tools,
    required this.pdkRoot,
    required this.pdks,
  });

  /// One row per [FlowTool].
  final List<FlowToolReport> tools;

  /// The PDK root looked in, or null when none is set anywhere.
  final String? pdkRoot;

  /// The PDKs found under it (`sky130A`, `gf180mcuD`, ...).
  final List<String> pdks;

  /// The tools that did not answer.
  List<FlowTool> get missing => <FlowTool>[
    for (final row in tools)
      if (!row.found) row.tool,
  ];
}

/// Runs `binary args` for the probe: exit code and non-empty lines, or null
/// when it could not be started or did not answer in time.
typedef FlowProbeRunner =
    Future<({int exitCode, List<String> lines})?> Function(
      String binary,
      List<String> args,
    );

/// Detects the implementation-flow toolchain and says what to do about what
/// is missing: detect and guide, never bundle, the formal probe's posture.
///
/// Every spawn goes through the [ProcessReaper], is bounded by
/// [kSpawnTimeout] and is killed as a tree when it overstays. The PDK check
/// only lists `PDK_ROOT`: it reads no PDK file. LibreLane is asked through
/// the `path` launcher only; a Nix or Docker launcher is checked by asking
/// `nix` or `docker` for their versions, never by building an environment.
class FlowToolchainProbe {
  /// Creates the probe. [runner] defaults to a bounded reaper spawn;
  /// [platform] and [environment] to the host's.
  FlowToolchainProbe({
    FlowProbeRunner? runner,
    ProcessReaper? reaper,
    RiscvHostPlatform? platform,
    Map<String, String>? environment,
  }) : // Private fields, so not initializing formals (`this._x` would make
       // the parameter private too).
       // ignore: prefer_initializing_formals
       _reaper = reaper,
       // Private for the same reason as `_reaper` above.
       // ignore: prefer_initializing_formals
       _runner = runner,
       platform =
           platform ??
           RiscvHostPlatform.fromFlags(
             isMacOS: Platform.isMacOS,
             isWindows: Platform.isWindows,
           ),
       _environment = environment ?? Platform.environment;

  final ProcessReaper? _reaper;
  final FlowProbeRunner? _runner;
  final Map<String, String> _environment;

  /// The host platform the guidance is phrased for.
  final RiscvHostPlatform platform;

  /// How long one probe spawn may take.
  static const Duration kSpawnTimeout = Duration(seconds: 15);

  /// Probes every [FlowTool] and the PDK root.
  ///
  /// [nextpnrPath] is the Settings path for nextpnr (a directory holding the
  /// nextpnr binaries and Yosys, or one binary); [librelanePath] the
  /// LibreLane path; [settings] the rest of Implementation flow.
  Future<FlowToolchainReport> probe({
    String? nextpnrPath,
    String? librelanePath,
    FlowToolSettings settings = const FlowToolSettings(),
  }) async {
    String inDir(String? configured, String name) {
      if (configured == null || configured.isEmpty) return name;
      if (Directory(configured).existsSync()) {
        return p.join(configured, _exe(name));
      }
      return p.basename(configured) == _exe(name)
          ? configured
          : p.join(p.dirname(configured), _exe(name));
    }

    String binaryFor(FlowTool tool) => switch (tool) {
      FlowTool.librelane => inDir(librelanePath, tool.binaryName),
      FlowTool.yosys ||
      FlowTool.nextpnrIce40 ||
      FlowTool.nextpnrEcp5 ||
      FlowTool.nextpnrHimbaechel => inDir(nextpnrPath, tool.binaryName),
      FlowTool.openroad =>
        settings.openroadPath.isEmpty ? tool.binaryName : settings.openroadPath,
      FlowTool.klayout =>
        settings.klayoutPath.isEmpty ? tool.binaryName : settings.klayoutPath,
      FlowTool.fusesoc =>
        settings.fusesocPath.isEmpty ? tool.binaryName : settings.fusesocPath,
      FlowTool.nix || FlowTool.docker => tool.binaryName,
    };

    final rows = <FlowToolReport>[];
    for (final tool in FlowTool.values) {
      final binary = binaryFor(tool);
      final run = await (_runner ?? _defaultRun)(binary, tool.versionArgs);
      final ok = run != null && run.exitCode == 0 && run.lines.isNotEmpty;
      rows.add(
        FlowToolReport(
          tool: tool,
          binary: binary,
          found: ok,
          version: ok ? run.lines.first : null,
        ),
      );
    }
    final root = settings.pdkRoot.isNotEmpty
        ? settings.pdkRoot
        : _environment['PDK_ROOT'];
    return FlowToolchainReport(
      tools: List<FlowToolReport>.unmodifiable(rows),
      pdkRoot: root == null || root.isEmpty ? null : root,
      pdks: root == null || root.isEmpty ? const <String>[] : pdksIn(root),
    );
  }

  /// The PDKs under [root]: each `<root>/<pdk>/` that holds `libs.ref`, the
  /// enabled-PDK layout ciel and volare both expose.
  static List<String> pdksIn(String root) {
    try {
      return <String>[
        // Links followed: ciel and volare expose the enabled PDK as one.
        for (final e in Directory(root).listSync())
          if (e is Directory &&
              Directory(p.join(e.path, 'libs.ref')).existsSync())
            p.basename(e.path),
      ]..sort();
    } on FileSystemException {
      return const <String>[];
    }
  }

  /// Plain-English guidance for a missing [tool] on [platform].
  String guidanceFor(FlowTool tool) {
    final what = '`${tool.binaryName}`';
    return switch (tool) {
      FlowTool.librelane ||
      FlowTool.nix ||
      FlowTool.docker => switch (platform) {
        RiscvHostPlatform.windows =>
          '$what was not found. LibreLane runs on Windows under WSL2 or '
              'Docker; ingesting a run directory works natively.',
        _ =>
          '$what was not found. LibreLane under Nix is the recommended '
              'install; set the launcher and the LibreLane path in Settings > '
              'Engines.',
      },
      FlowTool.openroad || FlowTool.klayout =>
        '$what was not found. It opens a run for a closer look; install it, '
            'or set its path in Settings > Engines.',
      FlowTool.fusesoc =>
        '$what was not found. Install FuseSoC (pip install fusesoc) or set '
            'its path in Settings > Engines.',
      FlowTool.yosys ||
      FlowTool.nextpnrIce40 ||
      FlowTool.nextpnrEcp5 ||
      FlowTool.nextpnrHimbaechel => switch (platform) {
        RiscvHostPlatform.macos =>
          '$what was not found. Install the OSS CAD Suite and set the nextpnr '
              'path in Settings > Engines to its bin directory: an app opened '
              "from Finder does not see your shell's PATH.",
        _ =>
          '$what was not found. The OSS CAD Suite ships Yosys and nextpnr '
              'together; set the nextpnr path in Settings > Engines to its bin '
              'directory, or put it on PATH.',
      },
    };
  }

  String _exe(String name) =>
      platform == RiscvHostPlatform.windows ? '$name.exe' : name;

  Future<({int exitCode, List<String> lines})?> _defaultRun(
    String binary,
    List<String> args,
  ) async {
    final reaper = _reaper ?? defaultProcessReaper();
    try {
      final env = <String, String>{};
      final dirs = engineSearchDirs();
      if (dirs.isNotEmpty) {
        final augmented = appendMissingPathDirs(
          Platform.environment['PATH'] ?? '',
          dirs,
          separator: Platform.isWindows ? ';' : ':',
          caseInsensitive: Platform.isWindows,
        );
        if (augmented != null) env['PATH'] = augmented;
      }
      final process = await reaper.spawnGrouped(
        binary,
        args,
        environment: env.isEmpty ? null : env,
      );
      final lines = <String>[];
      void add(String line) {
        final t = line.trim();
        if (t.isNotEmpty && lines.length < 50) lines.add(t);
      }

      final out = process.stdout.listen(add);
      final err = process.stderr.listen(add);
      final code = await process.exitCode.timeout(
        kSpawnTimeout,
        onTimeout: () {
          unawaited(reaper.terminateTree(process));
          return -1;
        },
      );
      await out.cancel();
      await err.cancel();
      if (code == -1) return null;
      return (exitCode: code, lines: lines);
    } on Object {
      return null;
    }
  }
}
