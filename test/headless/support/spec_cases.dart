// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// `spec/mcp/cases.json`: each golden document, the tool call that answers
/// it, and the exit code the command line ends with for the same arguments.
///
/// The cases run against a copy of `spec/fixtures/` in a temporary root
/// (the `@ROOT@` in the committed `results.ndjson` files becomes that root),
/// so no test writes into the committed tree. Goldens write the root as
/// `/spec/fixtures` and the program version as `0.0.0`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crux_mcp/crux_mcp.dart' hide HeadlessTelemetry;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/core/cli/simcrux_cli.dart';
import 'package:simcrux/headless/sim_document.dart';
import 'package:simcrux/headless/simcrux_mcp.dart';

import 'spec_scheduler.dart';

/// One case of `cases.json`.
class SpecCase {
  SpecCase._(Map<String, Object?> json)
    : golden = json['golden']! as String,
      tool = json['tool']! as String,
      arguments = json['arguments']! as Map<String, Object?>,
      exit = json['exit'] as int?,
      door = json['door'] as String? ?? 'both';

  /// A case made in code, answered by both doors.
  SpecCase.of({
    required this.golden,
    required this.tool,
    required this.arguments,
  }) : exit = null,
       door = 'both';

  /// The golden's path under `spec/mcp/goldens/`.
  final String golden;

  /// The tool called.
  final String tool;

  /// Its arguments.
  final Map<String, Object?> arguments;

  /// The command line's exit code, for a case both doors answer.
  final int? exit;

  /// `both`, or `mcp` for a call the server refuses before any command.
  final String door;

  @override
  String toString() => golden;
}

/// The cases, and the temporary root they run in.
class SpecCases {
  SpecCases._(this.cases, this.tmp, this.root, this._json);

  /// Reads `cases.json` and installs the fixtures into a fresh root.
  factory SpecCases.load() {
    final json =
        jsonDecode(File(p.join('spec', 'mcp', 'cases.json')).readAsStringSync())
            as Map<String, Object?>;
    final tmp = Directory.systemTemp
        .createTempSync('simcrux_spec_')
        .resolveSymbolicLinksSync();
    final root = p.join(tmp, 'root');
    final placeholder = json['root_placeholder']! as String;
    final from = Directory(json['root']! as String);
    for (final e in from.listSync(recursive: true)) {
      if (e is! File) continue;
      final target = File(p.join(root, p.relative(e.path, from: from.path)))
        ..createSync(recursive: true);
      if (e.path.endsWith('.ndjson')) {
        target.writeAsStringSync(
          e.readAsStringSync().replaceAll(placeholder, root),
        );
      } else {
        target.writeAsBytesSync(e.readAsBytesSync());
      }
    }
    // A project outside the root, which would run if it were not refused.
    File(p.join(tmp, 'outside', 'simcrux.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        File(p.join(root, 'allpass', 'simcrux.yaml')).readAsStringSync(),
      );
    File(p.join(tmp, 'outside', 'more.yaml')).writeAsStringSync(
      "version: '1'\nsuites: {}\n",
    );
    return SpecCases._(
      <SpecCase>[
        for (final c in json['cases']! as List<Object?>)
          SpecCase._(c! as Map<String, Object?>),
      ],
      tmp,
      root,
      json,
    );
  }

  /// Every case.
  final List<SpecCase> cases;

  /// The temporary directory holding [root].
  final String tmp;

  /// The root the cases run in.
  final String root;

  final Map<String, Object?> _json;

  /// The program the goldens name.
  McpProgram get goldenProgram => McpProgram(
    name: kSimcruxProgramName,
    version: _json['golden_version']! as String,
  );

  /// The clock `run` reads.
  DateTime get clock => DateTime.parse(_json['clock']! as String);

  /// Removes the root.
  void dispose() {
    if (Directory(tmp).existsSync()) {
      Directory(tmp).deleteSync(recursive: true);
    }
  }

  /// A CLI over the spec's scheduler, naming [program] (the goldens' unless
  /// given), deciding outcomes with [classify] unless null.
  SimcruxCli cli({McpProgram? program, SimRunClassifier? classify}) =>
      SimcruxCli(
        program: program ?? goldenProgram,
        classify: classify ?? classifySimRun,
        runSchedulerFactory: (_) => SpecScheduler(root: root),
        runRoot: p.join(tmp, 'scratch'),
        now: () => clock,
        mcpTelemetry: () => null,
      );

  McpTool _tool(String name) =>
      kSimcruxMcpTools.firstWhere((t) => t.name == name);

  /// The tool result of [c] from [cli]'s server.
  Future<Map<String, Object?>> callTool(SimcruxCli cli, SpecCase c) async {
    final line = await cli
        .server(root: root, log: (_) {})
        .handleLine(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'tools/call',
            'params': <String, Object?>{
              'name': c.tool,
              'arguments': c.arguments,
            },
          }),
        );
    return (jsonDecode(line!) as Map<String, Object?>)['result']!
        as Map<String, Object?>;
  }

  /// The text of [result]'s only content item.
  static String text(Map<String, Object?> result) =>
      ((result['content']! as List<Object?>).single!
              as Map<String, Object?>)['text']!
          as String;

  /// The command line the server runs for [c]: the tool's argument vector,
  /// then `--root` and `--json`, as `SimcruxCli.server` adds them.
  List<String> argv(SpecCase c) {
    final checked = _tool(c.tool).check(c.arguments, Confinement(root));
    if (checked is! McpArguments) {
      throw StateError('$c: the arguments are refused');
    }
    return <String>[
      _tool(c.tool).command,
      ...checked.argv,
      '--root',
      root,
      '--json',
    ];
  }

  /// What `simcrux <argv>` writes on stdout, and its exit code.
  Future<(String, int)> runCommandLine(
    SimcruxCli cli,
    List<String> argv,
  ) async {
    final out = <String>[];
    final code = await cli.run(argv, stdoutSink: out.add, stderrSink: (_) {});
    return ('${out.join('\n')}\n', code);
  }

  /// [text] with this machine's root written as the goldens write it, and
  /// the temporary directory around it as `/spec`.
  String normalize(String text) => text
      .replaceAll(root, _json['golden_root']! as String)
      .replaceAll(tmp, '/spec');

  /// The golden of [c]. A missing golden fails the test, after writing what
  /// the tool answered to `build/spec-actual/` for a person to check by
  /// hand against the fixtures before committing it.
  String golden(SpecCase c, {String? actual}) {
    final file = File(p.join('spec', 'mcp', 'goldens', c.golden));
    if (!file.existsSync()) {
      if (actual != null) {
        File(p.join('build', 'spec-actual', c.golden))
          ..createSync(recursive: true)
          ..writeAsStringSync(actual);
      }
      fail('no golden ${file.path}; the answer is in build/spec-actual/');
    }
    return file.readAsStringSync();
  }
}
