// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// The four tools of `simcrux mcp`, and what the server checks before it
/// lets `run` start.
///
/// Each tool's fields make both its `inputSchema` and the command line it
/// runs (`crux_mcp`'s `McpTool`), and the server runs that command line's
/// own code in process (`SimcruxCli`), so a tool's text is byte for byte
/// what `simcrux <command> ... --json` writes. Not offered, in any form:
/// `--allow-project-tooling` (it runs what a project file names), exports
/// and `--keep-failures` (they write or delete beyond what `run` says), and
/// `--fail-threshold` and `--fail-on-vacuous` (they move the gate).
library;

import 'dart:io';

import 'package:crux_mcp/crux_mcp.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/core/app_info/build_info.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/headless/sim_document.dart';
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/config/project_output_path.dart';

/// The `instructions` paragraph `initialize` returns. The full text is
/// `docs/agent/SIMCRUX.md`.
const String kSimcruxMcpInstructions =
    'SimCrux runs simulation and formal regressions from a simcrux.yaml. '
    'Call run to run one and get each test with its status, failure message, '
    'log and waveform, failures first; results, test and trend read runs '
    'already written, from their results.ndjson. An unknown test is a failed '
    'test, and a run in which no test produced a result is engine_error, '
    'never a pass. Cite a test by its log file:line, and its waveform by '
    "file. A failing test is a person's to waive: never edit a test, a "
    'threshold or a config to make a run pass.';

/// The `run` tool: `simcrux run <config> --json`.
final McpTool kRunTool = McpTool(
  name: kRunCommand,
  description:
      "Run a regression from its simcrux.yaml and return each test's status, "
      'failure message, log and waveform, failures first. Writes what '
      'simcrux --ci writes for that config. Long; cancelling stops it.',
  fields: const <McpField>[
    McpField('config', kind: McpFieldKind.path),
    McpField(
      'filter',
      kind: McpFieldKind.text,
      flag: '--filter',
      description: 'Only tests whose id contains this.',
    ),
    McpField(
      'max_parallel',
      kind: McpFieldKind.integer,
      flag: '--max-parallel',
      minimum: 1,
    ),
    McpField(
      'limit',
      kind: McpFieldKind.integer,
      flag: '--limit',
      minimum: 1,
      description: 'Tests returned, default 100, at most 1000.',
    ),
  ],
  required: const <String>['config'],
  checkNamedFiles: checkConfigFiles,
);

/// The `results` tool: `simcrux results <results.ndjson> --json`.
final McpTool kResultsTool = McpTool(
  name: kResultsCommand,
  description:
      'The results of a finished run, read from its results.ndjson. Runs '
      'nothing.',
  fields: const <McpField>[
    McpField('results', kind: McpFieldKind.path),
    McpField(
      'status',
      kind: McpFieldKind.text,
      flag: '--status',
      many: true,
      description: 'For example fail, timeout, unknown.',
    ),
    McpField(
      'limit',
      kind: McpFieldKind.integer,
      flag: '--limit',
      minimum: 1,
      description: 'Default 100, at most 1000.',
    ),
  ],
  required: const <String>['results'],
);

/// The `test` tool: `simcrux test <results.ndjson> <suite/test> --json`.
final McpTool kTestTool = McpTool(
  name: kTestCommand,
  description:
      'One test of a run: status, failure message, the end of its log with '
      'the first failing line, seed and parameters, and its waveform.',
  fields: const <McpField>[
    McpField('results', kind: McpFieldKind.path),
    McpField('id', kind: McpFieldKind.text, description: 'suite/test'),
    McpField(
      'lines',
      kind: McpFieldKind.integer,
      flag: '--lines',
      minimum: 1,
      description: 'Log lines, default 100, at most 1000.',
    ),
  ],
  required: const <String>['results', 'id'],
);

/// The `trend` tool: `simcrux trend <suite/test> <results.ndjson>... --json`.
///
/// `id` comes before `runs` in the field list because positional arguments
/// follow field order and the command takes the test first.
final McpTool kTrendTool = McpTool(
  name: kTrendCommand,
  description:
      "A test's history across runs: status and runtime in each. At Pro, "
      'also its flakiness class.',
  fields: const <McpField>[
    McpField('id', kind: McpFieldKind.text),
    McpField(
      'runs',
      kind: McpFieldKind.path,
      many: true,
      description: 'results.ndjson files, any order, at most 200.',
    ),
  ],
  required: const <String>['runs', 'id'],
);

/// The tools the open-core server lists, in order.
final List<McpTool> kSimcruxMcpTools = <McpTool>[
  kRunTool,
  kResultsTool,
  kTestTool,
  kTrendTool,
];

/// The `mcp.tool_call` counter of the open-core binary: sent only under the
/// consent the SimCrux desktop app recorded on this machine, and never when
/// the `CI` environment variable is set.
McpTelemetry simcruxMcpTelemetry() => McpTelemetry.desktop(
  HeadlessTelemetry(
    product: CruxTelemetryProduct.simcrux,
    pro: false,
    appVersion: SimCruxBuildInfo.productVersion,
  ),
);

/// Thrown by the reader [checkConfigFiles] gives the loader when the
/// project names a file outside the root: the load stops before it opens it.
class _Outside implements Exception {
  const _Outside(this.refusal);
  final RefusedPath refusal;
}

/// The `named-files` check of `run`: the `simcrux.yaml` the call names is
/// read the way the run reads it (`ConfigLoader`, project tooling off), and
/// every file it reads on the way (included configs, filelists) and every
/// file and directory the loaded project names must be inside the root.
///
/// The loader reads through a reader that confines each path before it
/// opens it, so an include or a filelist outside the root is refused
/// without being read. A project that does not load for any other reason is
/// left to the command, which says why in its own document.
Future<RefusedPath?> checkConfigFiles(
  McpArguments arguments,
  Confinement confinement,
) async {
  final configPath = arguments.values['config'];
  if (configPath is! String) return null;
  if (FileSystemEntity.typeSync(configPath) != FileSystemEntityType.file) {
    return null;
  }
  // Recorded as well as thrown: the filelist reader turns any read failure
  // into a ConfigLoaderException, which would otherwise hide the refusal
  // and hand the project to a command that reads without this check.
  RefusedPath? refused;
  Future<String> confinedRead(String path) async {
    final refusal = confinement.confineAll(<String>[path]);
    if (refusal != null) {
      refused ??= refusal;
      throw _Outside(refusal);
    }
    return await File(path).readAsString();
  }

  RegressionConfig? config;
  try {
    config = await ConfigLoader(readFile: confinedRead).load(configPath);
  } on Object {
    config = null;
  }
  if (refused != null) return refused;
  if (config == null) return null;
  return confinement.confineAll(
    configNamedPaths(config),
    base: p.dirname(configPath),
  );
}

/// Every file and directory [config] (as loaded) names, relative ones
/// against the project's directory: each test's sources and include
/// directories; the formal block's `.sby` and `.eqy` files and demo
/// outputs; the RISC-V block's corpora, suite, test, check set, plugin and
/// link script; each flow entry's configuration, constraints and sources;
/// the flow ingest paths; and where the run writes its results.
///
/// A value holding a `{` placeholder is expanded at spawn time into a path
/// inside the test's work folder, and is not listed.
List<String> configNamedPaths(RegressionConfig config) {
  final root = p.dirname(config.projectFilePath);
  final out = <String>[];
  void add(String? path, {String? base}) {
    if (path == null || path.isEmpty || path.contains('{')) return;
    out.add(p.isAbsolute(path) ? path : p.join(base ?? root, path));
  }

  for (final suite in config.suites) {
    for (final test in suite.tests) {
      test.sources.forEach(add);
      test.includeDirs.forEach(add);
      final formal = test.formal;
      if (formal != null) {
        add(formal.sbyFile);
        add(formal.eqyFile);
        add(formal.demoOutputs);
      }
      final riscv = test.riscv;
      if (riscv != null) {
        add(riscv.demoSignatures);
        final suitePath = riscv.archTest?.suitePath;
        add(suitePath);
        add(riscv.testPath, base: suitePath ?? root);
        add(riscv.target?.pluginPath);
        add(riscv.compile?.linkScript);
        final checks = riscv.formal?.checksDir;
        add(checks);
        add(riscv.formal?.demoOutputs);
        add(riscv.formal?.sbyFile, base: checks ?? root);
      }
      final flow = test.flow;
      if (flow != null) {
        add(flow.config);
        add(flow.constraints);
        flow.sources.forEach(add);
      }
    }
  }
  final flow = config.flow;
  if (flow != null) {
    for (final entry in flow.entries) {
      add(entry.config);
      add(entry.constraints);
      entry.sources.forEach(add);
    }
    flow.ingest.forEach(add);
  }
  add(
    resolveProjectOutputPath(
      config.output.streamingResultsPath ?? 'results.ndjson',
      root,
    ),
  );
  add(
    resolveProjectOutputPath(
      config.output.streamingSummaryPath ?? 'results.summary.json',
      root,
    ),
  );
  return out;
}
