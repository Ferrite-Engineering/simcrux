// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@Tags(['integration', 'oss-cad-live'])
library;

// Live assertion of the formal fixture corpus: runs the real sby, eqy and
// yosys (with yosys-slang) on every fixture input in a scratch directory
// and checks the fresh output against the hand-written expectations, with
// the same checks the committed-capture test uses.
//
// It needs an OSS CAD Suite build: set OSS_CAD_SUITE to the directory
// holding its bin/, or put that bin/ on PATH (every tool is then taken
// from the directory of the `sby` found there). Without one every
// test here is skipped, so CI without the tools stays green, unless
// FORMAL_LIVE_REQUIRED=1, which turns a missing tool into a failure (the
// engine canary sets it). A disagreement means the tool changed or an
// expectation was wrong; read PROVENANCE.md for how to decide which, and
// never copy the tool's answer into the expectation.
//
// Tagged `oss-cad-live`: the CI `Test` job runs `flutter test -x oss-cad-live`
// so these tool-gated skips do not count against its skip ceiling.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/formal_fixture_checks.dart';

bool get _required => Platform.environment['FORMAL_LIVE_REQUIRED'] == '1';

/// Skips the test (or fails it under FORMAL_LIVE_REQUIRED=1) when [tool]
/// is absent.
void _markToolMissing(String tool) {
  final reason = '$tool not found; set OSS_CAD_SUITE or put it on PATH';
  if (_required) fail('FORMAL_LIVE_REQUIRED=1 and $reason');
  markTestSkipped(reason);
}

/// The suite's bin directory: OSS_CAD_SUITE/bin, else the directory of the
/// `sby` on PATH. Every tool comes from this one directory, so a stray
/// system Yosys (without the yosys-slang plugin) is never mixed with a
/// suite's sby.
final String? _suiteBin = () {
  final suite = Platform.environment['OSS_CAD_SUITE'];
  if (suite != null && suite.isNotEmpty) return p.join(suite, 'bin');
  final which = Process.runSync(Platform.isWindows ? 'where' : 'which', [
    'sby',
  ]);
  if (which.exitCode != 0) return null;
  final first = (which.stdout as String).split('\n').first.trim();
  return first.isEmpty ? null : p.dirname(first);
}();

/// Absolute path of [tool] in the suite, or null.
String? _tool(String tool) {
  final bin = _suiteBin;
  if (bin == null) return null;
  final candidate = p.join(bin, tool);
  return File(candidate).existsSync() ? candidate : null;
}

/// Whether [yosys] can load the yosys-slang plugin.
bool _hasSlang(String yosys) =>
    Process.runSync(yosys, ['-Q', '-q', '-p', 'plugin -i slang']).exitCode == 0;

String get _root => p.absolute(kFormalFixtureRoot);

/// Copies the files of [from] (not its subdirectories) matching [keep].
void _copyInputs(String from, String to, bool Function(String) keep) {
  Directory(to).createSync(recursive: true);
  for (final f in Directory(from).listSync().whereType<File>()) {
    if (keep(f.path)) f.copySync(p.join(to, p.basename(f.path)));
  }
}

String? _readIfExists(String path) {
  final f = File(path);
  return f.existsSync() ? f.readAsStringSync() : null;
}

void main() {
  late Directory scratch;

  setUpAll(() {
    scratch = Directory.systemTemp.createTempSync('simcrux_formal_live_');
  });
  tearDownAll(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  for (final name in kFormalSbyCases) {
    test('sby/$name: a live run matches the hand expectation', () async {
      final sby = _tool('sby');
      if (sby == null) {
        _markToolMissing('sby');
        return;
      }
      final caseDir = p.join(_root, 'sby', name);
      expect(Directory(caseDir).existsSync(), isTrue, reason: caseDir);
      final work = p.join(scratch.path, 'sby', name);
      _copyInputs(
        caseDir,
        work,
        (f) => f.endsWith('.sv') || f.endsWith('.v') || f.endsWith('.sby'),
      );
      await Process.run(sby, ['-f', '$name.sby'], workingDirectory: work);
      final status = await Process.run(sby, [
        '--statusfmt',
        'jsonl',
        '$name.sby',
      ], workingDirectory: work);
      final problems = checkSbyCase(
        expected: readJsonObject(p.join(caseDir, '$name.expected.json')),
        taskLog: (task) =>
            _readIfExists(p.join(work, '${name}_$task', 'logfile.txt')),
        taskFile: (task, rel) =>
            _readIfExists(p.join(work, '${name}_$task', rel)),
        statusJsonl: status.stdout as String,
      );
      expect(problems, isEmpty, reason: problems.join('\n'));
    }, timeout: const Timeout(Duration(minutes: 10)));
  }

  test('eqy: live runs match the hand expectations', () async {
    final eqy = _tool('eqy');
    if (eqy == null) {
      _markToolMissing('eqy');
      return;
    }
    final eqyDir = p.join(_root, 'eqy');
    final expected = readJsonObject(p.join(eqyDir, 'eqy.expected.json'));
    final runs = expected['runs']! as Map<String, Object?>;
    final work = p.join(scratch.path, 'eqy');
    _copyInputs(
      eqyDir,
      work,
      (f) => f.endsWith('.v') || f.endsWith('.eqy'),
    );
    final problems = <String>[];
    for (final run in kFormalEqyRuns) {
      await Process.run(eqy, ['-f', '$run.eqy'], workingDirectory: work);
      final log = _readIfExists(p.join(work, run, 'logfile.txt')) ?? '';
      problems.addAll(
        checkEqyRun(
          runs[run]! as Map<String, Object?>,
          log,
        ).map((m) => '$run: $m'),
      );
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('sva_matrix: live frontend runs match the hand expectations', () async {
    final yosys = _tool('yosys');
    if (yosys == null) {
      _markToolMissing('yosys');
      return;
    }
    if (!_hasSlang(yosys)) {
      _markToolMissing('the yosys-slang plugin for $yosys');
      return;
    }
    final expected = readJsonObject(
      p.join(_root, 'sva_matrix', 'sva_matrix.expected.json'),
    );
    final problems = <String>[];
    final cells = p.join(scratch.path, 'cells.txt');
    const count =
        r'select -count t:$assert t:$assume t:$cover t:$check t:$live t:$fair';
    for (final probe in objectList(expected['probes'])) {
      final name = probe['probe']! as String;
      final source = p.join(_root, 'sva_matrix', 'probes', '$name.sv');
      expect(File(source).existsSync(), isTrue, reason: source);
      for (final fe in kFormalSvaFrontends) {
        final read = fe == 'builtin'
            ? 'read_verilog -formal -sv $source'
            : 'plugin -i slang; read_slang $source --top m';
        final cellsFile = File(cells);
        if (cellsFile.existsSync()) cellsFile.deleteSync();
        final result = await Process.run(yosys, [
          '-Q',
          '-q',
          '-p',
          '$read; prep -top m; tee -o $cells $count',
        ]);
        final n = cellsFile.existsSync()
            ? int.tryParse(
                RegExp(r'^\d+').stringMatch(cellsFile.readAsStringSync()) ?? '',
              )
            : null;
        problems.addAll(
          checkSvaProbe(
            probe: probe,
            frontend: fe,
            exitCode: result.exitCode,
            cells: n,
            log: '${result.stdout}${result.stderr}',
          ).map((m) => '$name $fe: $m'),
        );
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 10)));
}
