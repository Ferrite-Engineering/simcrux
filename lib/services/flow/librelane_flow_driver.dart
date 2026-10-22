// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:crux_flow/crux_flow.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/domain/models/flow_tool_settings.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/services/flow/flow_process_driver.dart';
import 'package:simcrux/services/flow/flow_run_reading.dart';

/// The command line a LibreLane entry runs, worked out before anything is
/// spawned.
@immutable
class LibreLaneInvocation {
  /// Creates the invocation.
  const LibreLaneInvocation({
    required this.argv,
    required this.runRoot,
    required this.tag,
    required this.launcher,
    this.workingDirectory,
    this.container,
    this.environment = const <String, String>{},
  });

  /// The whole command line, executable first.
  final List<String> argv;

  /// `runs/<tag>/` beside the configuration.
  final String runRoot;

  /// The run tag, one generated safe segment.
  final String tag;

  /// How LibreLane is started.
  final FlowLauncher launcher;

  /// Where the process starts: the design directory.
  final String? workingDirectory;

  /// The container name the `docker` launcher gives the run, so a cancel
  /// can stop it.
  final String? container;

  /// Variables added to the child environment (`PDK_ROOT`).
  final Map<String, String> environment;
}

/// Reads a finished or stopped LibreLane run directory. A seam: the
/// documented-contract reader stands in until the versioned LibreLane
/// readers replace it.
typedef LibreLaneRunReading =
    Future<FlowReading> Function(
      String runRoot, {
      String? tag,
    });

/// Runs a LibreLane entry.
///
/// `compile` is a no-op; `execute` starts LibreLane through the entry's
/// launcher:
///
/// - `path`: `librelane [--pdk-root ROOT] [--pdk PDK] --run-tag TAG CONFIG`;
/// - `nix`: `nix develop CHECKOUT --command librelane ...`, the checkout
///   being the LibreLane path Settings names;
/// - `docker`: `docker run --rm --name simcrux-TAG -v DESIGN:DESIGN
///   [-v PDK_ROOT:PDK_ROOT] -w DESIGN IMAGE librelane ...`, so a cancel stops
///   the named container as well as the client.
///
/// **Never `--overwrite`, never `--last-run`.** The tag is
/// `<tag_prefix>-<UTC timestamp>`, one generated safe segment, and a tag
/// whose directory exists is never reused, so LibreLane never deletes or
/// resumes a run SimCrux did not create. Nothing here deletes anything under
/// a run root.
///
/// Progress is polled with `dart:io`: the run root's top level, for new
/// `NN-<tool>-<step>` directories, every [pollInterval]. Cancel kills the
/// whole process tree (Yosys, OpenROAD, Magic, KLayout, Netgen are its
/// children) through the reaper, and for `docker` also runs `docker stop`.
///
/// The verdict comes from the run's records, never the exit code
/// (LibreLane exits non-zero when a checker flags a violation): see
/// [LibreLaneContractReader].
///
/// **Never gated.** A flow verdict is correctness and is free.
class LibreLaneFlowDriver extends FlowProcessDriver {
  /// Creates the driver.
  LibreLaneFlowDriver({
    super.launcher,
    super.reaper,
    super.killGrace,
    super.clock,
    this.pollInterval = const Duration(seconds: 2),
    LibreLaneRunReading? readRun,
    this.hostEnvironment,
  }) : _readRun = readRun ?? const LibreLaneContractReader().read;

  /// The `simulatorId` this driver claims.
  static const String kId = 'librelane';

  /// How often the run root is listed for new step directories.
  final Duration pollInterval;

  final LibreLaneRunReading _readRun;

  /// The environment `XDG_DATA_HOME` is looked up in; this process's when
  /// null. Tests pass one without it.
  final Map<String, String>? hostEnvironment;

  final Map<String, String> _containers = <String, String>{};

  @override
  String get id => kId;

  @override
  String get displayName => 'LibreLane';

  @override
  bool get requiresCompile => false;

  /// Cheap by design: the version of a `librelane` executable named by path
  /// or on PATH, and never a spawn of `nix develop` or `docker` (a Nix
  /// launcher would build a whole environment to answer).
  @override
  Future<String?> detectVersion(SimulatorBinaryConfig config) async {
    final settings = FlowToolSettings.fromOptions(config.options);
    if (settings.launcher != FlowLauncher.path) return null;
    return await detectVersionOf(flowBinary(config, 'librelane'));
  }

  @override
  Future<CompileResult> compile(CompileRequest request) async =>
      const CompileResult(
        success: true,
        artifactPath: null,
        stdout: '',
        stderr: '',
      );

  @override
  void cancel(String testId) {
    super.cancel(testId);
    final container = _containers.remove(testId);
    if (container != null) unawaited(_stopContainer(container));
  }

  Future<void> _stopContainer(String name) async {
    try {
      final process = await reaper.spawnGrouped('docker', <String>[
        'stop',
        '--time',
        '10',
        name,
      ], environment: augmentEnvironment(null));
      // The exit code is not checked: a container that already stopped
      // answers non-zero, which is the outcome wanted.
      await process.exitCode.timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          unawaited(reaper.terminateTree(process, grace: killGrace));
          return -1;
        },
      );
    } on Object {
      // Docker gone or the container already removed: nothing left to stop.
    }
  }

  /// The invocation for [entry], or a reason it cannot run.
  ///
  /// [config] carries the Settings values; a project's `launcher`,
  /// `librelane_binary` and `docker_image` reached [entry] only under
  /// project-tooling consent.
  @visibleForTesting
  ({LibreLaneInvocation? invocation, String? problem, String? toolMissing})
  prepare(FlowEntry entry, SimulatorBinaryConfig config) {
    final root = entry.projectRoot;
    final configFile = entry.config;
    if (root == null || configFile == null) {
      return (
        invocation: null,
        problem: 'the entry names no LibreLane configuration',
        toolMissing: null,
      );
    }
    final containment = FlowContainment(<String>[root]);
    final String design;
    final String configPath;
    final String runs;
    try {
      configPath = containment.require(configFile);
      design = p.dirname(configPath);
      runs = containment.require(p.join(design, 'runs'));
    } on FlowContainmentException catch (e) {
      return (
        invocation: null,
        problem: 'the configuration: ${e.reason}',
        toolMissing: null,
      );
    }
    if (!File(configPath).existsSync()) {
      return (
        invocation: null,
        problem: 'the configuration file does not exist',
        toolMissing: null,
      );
    }
    final tag = FlowProcessDriver.freshTag(runs, entry.tagPrefix, clock());
    if (tag == null) {
      return (
        invocation: null,
        problem: 'no free run tag could be made',
        toolMissing: null,
      );
    }
    final String runRoot;
    try {
      runRoot = containment.require(p.join(runs, tag));
    } on FlowContainmentException catch (e) {
      return (
        invocation: null,
        problem: 'the run directory: ${e.reason}',
        toolMissing: null,
      );
    }

    final settings = FlowToolSettings.fromOptions(config.options);
    final launcherKind = entry.launcher ?? settings.launcher;
    final pdkRoot = settings.pdkRoot;
    final librelaneArgs = <String>[
      if (pdkRoot.isNotEmpty) ...['--pdk-root', pdkRoot],
      if (entry.pdk != null) ...['--pdk', entry.pdk!],
      '--run-tag',
      tag,
      configPath,
    ];
    final env = <String, String>{if (pdkRoot.isNotEmpty) 'PDK_ROOT': pdkRoot};
    switch (launcherKind) {
      case FlowLauncher.path:
        final binary = entry.librelaneBinary ?? flowBinary(config, 'librelane');
        return (
          invocation: LibreLaneInvocation(
            argv: <String>[binary, ...librelaneArgs],
            runRoot: runRoot,
            tag: tag,
            launcher: launcherKind,
            workingDirectory: design,
            environment: env,
          ),
          problem: null,
          toolMissing: null,
        );
      case FlowLauncher.nix:
        final checkout = config.customPath;
        if (checkout == null ||
            checkout.isEmpty ||
            !Directory(checkout).existsSync()) {
          return (
            invocation: null,
            problem:
                'the nix launcher needs a LibreLane checkout: set the '
                'LibreLane path in Settings > Engines to the directory that '
                'holds its flake.',
            toolMissing: 'nix',
          );
        }
        return (
          invocation: LibreLaneInvocation(
            argv: <String>[
              'nix',
              'develop',
              checkout,
              '--command',
              'librelane',
              ...librelaneArgs,
            ],
            runRoot: runRoot,
            tag: tag,
            launcher: launcherKind,
            workingDirectory: design,
            environment: env,
          ),
          problem: null,
          toolMissing: null,
        );
      case FlowLauncher.docker:
        final image = entry.dockerImage ?? settings.dockerImage;
        if (image.isEmpty) {
          return (
            invocation: null,
            problem:
                'the docker launcher needs an image: set the LibreLane Docker '
                'image in Settings > Engines.',
            toolMissing: 'docker',
          );
        }
        final container = 'simcrux-$tag';
        return (
          invocation: LibreLaneInvocation(
            argv: <String>[
              'docker',
              'run',
              '--rm',
              '--name',
              container,
              '-v',
              '$design:$design',
              if (pdkRoot.isNotEmpty) ...['-v', '$pdkRoot:$pdkRoot'],
              if (pdkRoot.isNotEmpty) ...['-e', 'PDK_ROOT=$pdkRoot'],
              '-w',
              design,
              image,
              'librelane',
              ...librelaneArgs,
            ],
            runRoot: runRoot,
            tag: tag,
            launcher: launcherKind,
            workingDirectory: design,
            container: container,
          ),
          problem: null,
          toolMissing: null,
        );
    }
  }

  @override
  Future<void> runExecute(
    ExecuteRequest request,
    StreamController<TestExecutionEvent> controller,
  ) async {
    final startedAt = DateTime.now().toUtc();
    final entry = entryOf(request.test, FlowKind.librelane);
    if (entry == null) {
      await failBeforeRunning(
        controller,
        startedAt: startedAt,
        kind: FlowKind.librelane,
        root: '',
        tag: '',
        problem: 'this test has no LibreLane flow entry',
      );
      return;
    }
    final prepared = prepare(entry, request.binaryConfig);
    final invocation = prepared.invocation;
    if (invocation == null) {
      await failBeforeRunning(
        controller,
        startedAt: startedAt,
        kind: FlowKind.librelane,
        root: '',
        tag: '',
        problem: prepared.problem!,
        toolMissing: prepared.toolMissing,
      );
      return;
    }
    final container = invocation.container;
    if (container != null) _containers[request.test.id] = container;

    final watcher = _StepWatcher(invocation.runRoot, controller);
    final timer = Timer.periodic(pollInterval, (_) => watcher.poll());
    final FlowSpawnOutcome outcome;
    try {
      outcome = await spawnTool(
        request: request,
        executable: invocation.argv.first,
        args: invocation.argv.skip(1).toList(growable: false),
        controller: controller,
        environment: FlowProcessDriver.flowEnvironment(
          request.workingDirectory,
          <String, String>{
            ...request.binaryConfig.extraEnv,
            ...invocation.environment,
          },
          hostEnvironment: hostEnvironment,
        ),
        workingDirectory: invocation.workingDirectory,
      );
    } finally {
      timer.cancel();
      _containers.remove(request.test.id);
    }
    if (outcome.notFound != null) {
      final tool = switch (invocation.launcher) {
        FlowLauncher.path => 'librelane',
        FlowLauncher.nix => 'nix',
        FlowLauncher.docker => 'docker',
      };
      await failBeforeRunning(
        controller,
        startedAt: startedAt,
        kind: FlowKind.librelane,
        root: invocation.runRoot,
        tag: invocation.tag,
        problem:
            '`${invocation.argv.first}` was not found. Install LibreLane '
            '(Nix is the recommended install) and set its launcher and path '
            'in Settings > Engines.',
        toolMissing: tool,
      );
      return;
    }
    watcher.poll();
    final reading = await _readRun(invocation.runRoot, tag: invocation.tag);
    controller.add(
      finishedFor(
        reading,
        startedAt: startedAt,
        exitCode: outcome.exitCode,
        killSignal: outcome.killSignal,
      ),
    );
    await controller.close();
  }
}

/// Lists a run root's top level and reports each new step directory once.
/// Reads only; never follows a link.
class _StepWatcher {
  _StepWatcher(this.runRoot, this.controller);

  final String runRoot;
  final StreamController<TestExecutionEvent> controller;
  final Set<String> _seen = <String>{};

  void poll() {
    final List<FileSystemEntity> entries;
    try {
      entries = Directory(runRoot).listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    final fresh = <String>[
      for (final e in entries)
        if (e is Directory &&
            kLibreLaneStepDirectory.hasMatch(p.basename(e.path)) &&
            _seen.add(p.basename(e.path)))
          p.basename(e.path),
    ]..sort();
    if (controller.isClosed) return;
    for (final name in fresh) {
      controller.add(
        TestLogLine(
          line: 'librelane: step $name',
          fromStderr: false,
          timestamp: DateTime.now().toUtc(),
        ),
      );
    }
  }
}
