// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crux_io/crux_io.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/riscv_host_platform.dart';
import 'package:simcrux/domain/models/formal_toolchain_report.dart';

/// What one probe spawn returned: the exit code and every non-empty output
/// line, stdout first.
typedef FormalProbeRun = ({int exitCode, List<String> lines});

/// Runs `binary args` for the probe and returns what it printed, or null
/// when it could not be started at all.
typedef FormalProbeRunner =
    Future<FormalProbeRun?> Function(String binary, List<String> args);

/// Locates the formal toolchain and says what to do about what is missing.
///
/// Detect and guide, never bundle, the RISC-V probe's posture: SimCrux
/// spawns what the user installed and conveys none of it.
///
/// ## Where it looks
///
/// SymbiYosys comes first: the Settings path for `sby` when one is set,
/// else `sby` on PATH (with the platform's engine directories appended, as
/// every spawn does, because a macOS app opened from Finder does not inherit
/// the shell's PATH). When `sby` is a path, every other tool is looked up
/// **beside it** first: an OSS CAD Suite keeps them all in one `bin/`, and
/// mixing that `sby` with a different Yosys on PATH is how a design that
/// proves in a terminal fails in the app.
///
/// ## What it asks
///
/// - `sby`, `eqy`: `--version`.
/// - `yosys`: `-V`, then whether it was built with Verific
///   (`verific -cfg` succeeds only then).
/// - yosys-slang: whether Yosys can load the `slang` plugin.
/// - The solvers and ABC: their version banner.
///
/// Non-throwing end to end. A tool that cannot be started, exits non-zero
/// or prints nothing is reported missing.
class FormalToolchainProbe {
  /// Creates a probe. [runner] defaults to a bounded real spawn; [platform]
  /// to the host. Both are injected by tests.
  FormalToolchainProbe({FormalProbeRunner? runner, RiscvHostPlatform? platform})
    : _run = runner ?? defaultRunner,
      platform =
          platform ??
          RiscvHostPlatform.fromFlags(
            isMacOS: Platform.isMacOS,
            isWindows: Platform.isWindows,
          );

  final FormalProbeRunner _run;

  /// The host platform the guidance is phrased for.
  final RiscvHostPlatform platform;

  /// How long one probe spawn may take before it counts as not answering.
  static const Duration kSpawnTimeout = Duration(seconds: 15);

  /// Probes every [FormalTool]. [sbyPath] is the Settings path for `sby`
  /// (a file, or a directory holding it), or null to use PATH; [eqyPath]
  /// likewise for `eqy`.
  Future<FormalToolchainReport> probe({
    String? sbyPath,
    String? eqyPath,
  }) async {
    final sby = _resolve(sbyPath, FormalTool.sby.binaryName);
    final siblings = p.isAbsolute(sby) ? p.dirname(sby) : null;
    String locate(FormalTool tool) {
      if (siblings == null) return tool.binaryName;
      final beside = p.join(siblings, _exe(tool.binaryName));
      return File(beside).existsSync() ? beside : tool.binaryName;
    }

    final rows = <FormalToolReport>[];
    for (final tool in FormalTool.values) {
      switch (tool) {
        case FormalTool.sby:
          rows.add(await _version(tool, sby, const <String>['--version']));
        case FormalTool.eqy:
          final eqy = eqyPath == null || eqyPath.isEmpty
              ? locate(tool)
              : _resolve(eqyPath, tool.binaryName);
          rows.add(await _version(tool, eqy, const <String>['--version']));
        case FormalTool.yosys:
          final yosys = locate(tool);
          final version = await _version(tool, yosys, const <String>['-V']);
          if (!version.found) {
            rows.add(version);
            break;
          }
          final verific = await _run(yosys, const <String>[
            '-q',
            '-p',
            'verific -cfg',
          ]);
          rows.add(
            FormalToolReport(
              tool: tool,
              binary: yosys,
              found: true,
              version: version.version,
              verific: verific != null && verific.exitCode == 0,
            ),
          );
        case FormalTool.yosysSlang:
          final yosys = locate(FormalTool.yosys);
          final slang = await _run(yosys, const <String>[
            '-q',
            '-m',
            'slang',
            '-p',
            'help read_slang',
          ]);
          rows.add(
            FormalToolReport(
              tool: tool,
              binary: yosys,
              found: slang != null && slang.exitCode == 0,
            ),
          );
        case FormalTool.yosysAbc:
          rows.add(
            await _version(tool, locate(tool), const <String>['-q', 'version']),
          );
        case FormalTool.yicesSmt2 ||
            FormalTool.boolector ||
            FormalTool.bitwuzla ||
            FormalTool.z3 ||
            FormalTool.ric3:
          rows.add(
            await _version(tool, locate(tool), const <String>['--version']),
          );
      }
    }
    return FormalToolchainReport(
      tools: List<FormalToolReport>.unmodifiable(rows),
    );
  }

  Future<FormalToolReport> _version(
    FormalTool tool,
    String binary,
    List<String> args,
  ) async {
    final run = await _run(binary, args);
    final ok = run != null && run.exitCode == 0 && run.lines.isNotEmpty;
    return FormalToolReport(
      tool: tool,
      binary: binary,
      found: ok,
      version: ok ? run.lines.first : null,
    );
  }

  /// [configured] as an executable: a file path verbatim, a directory
  /// joined with [name], or [name] itself when nothing is configured.
  String _resolve(String? configured, String name) {
    if (configured == null || configured.isEmpty) return name;
    if (Directory(configured).existsSync()) {
      return p.join(configured, _exe(name));
    }
    return configured;
  }

  String _exe(String name) =>
      platform == RiscvHostPlatform.windows ? '$name.exe' : name;

  /// The guidance for a missing [tool] on [platform], in plain English: the
  /// same channel as a driver's "not available" message. The Settings view
  /// shows localized copy of its own.
  String guidanceFor(FormalTool tool) {
    final what = tool == FormalTool.yosysSlang
        ? 'The yosys-slang plugin'
        : '`${tool.binaryName}`';
    final suffix = tool.essential
        ? ''
        : ' It is needed only by the jobs that use it.';
    return switch (platform) {
      RiscvHostPlatform.linux =>
        '$what was not found. The OSS CAD Suite ships Yosys, SymbiYosys, '
            'EQY, yosys-slang and the solvers together; unpack it and set the '
            'path to its sby in Settings > Engines, or put its bin directory '
            'on PATH.$suffix',
      RiscvHostPlatform.macos =>
        '$what was not found. Install the OSS CAD Suite, or Homebrew Yosys '
            'and SymbiYosys. An app opened from Finder does not see your '
            "shell's PATH, so set the path to sby in Settings > Engines; the "
            'other tools are then found beside it.$suffix',
      RiscvHostPlatform.windows =>
        '$what was not found. The OSS CAD Suite has a Windows build; running '
            'the formal flow under WSL2 is also common and better '
            'trodden.$suffix',
    };
  }

  /// The real spawn: bounded by [kSpawnTimeout], PATH augmented with the
  /// platform's engine directories, and never throwing.
  static Future<FormalProbeRun?> defaultRunner(
    String binary,
    List<String> args,
  ) async {
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
      final result = await Process.run(
        binary,
        args,
        environment: env.isEmpty ? null : env,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(kSpawnTimeout);
      final lines = <String>[
        ...const LineSplitter().convert('${result.stdout}'),
        ...const LineSplitter().convert('${result.stderr}'),
      ].map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
      return (exitCode: result.exitCode, lines: lines);
    } on Object {
      return null;
    }
  }
}
