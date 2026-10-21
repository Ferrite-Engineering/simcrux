// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/riscv_host_platform.dart';
import 'package:simcrux/domain/models/formal_toolchain_report.dart';
import 'package:simcrux/services/formal/formal_toolchain_probe.dart';

// The formal toolchain probe against a scripted runner: what it asks each
// tool, where it looks, and what it reports. The live probe against a real
// OSS CAD Suite is test/integration/formal_toolchain_probe_live_test.dart.

/// A runner that answers from [answers], keyed by `binary args`, and records
/// every call.
class _Script {
  _Script(this.answers);

  final Map<String, FormalProbeRun> answers;
  final List<String> calls = <String>[];

  Future<FormalProbeRun?> call(String binary, List<String> args) async {
    final key = '$binary ${args.join(' ')}';
    calls.add(key);
    return answers[key];
  }
}

FormalProbeRun _ok(String line) => (exitCode: 0, lines: <String>[line]);
const FormalProbeRun _fail = (exitCode: 1, lines: <String>['ERROR']);

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('formal_probe_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('with nothing configured, every tool is looked up on PATH', () async {
    final script = _Script({
      'sby --version': _ok('SBY v0.70'),
      'yosys -V': _ok('Yosys 0.70'),
      'yosys -q -p verific -cfg': _fail,
      'yosys -q -m slang -p help read_slang': _ok(''),
      'yices-smt2 --version': _ok('Yices 2.7.0'),
    });
    final report = await FormalToolchainProbe(
      runner: script.call,
      platform: RiscvHostPlatform.linux,
    ).probe();

    expect(report[FormalTool.sby]!.found, isTrue);
    expect(report[FormalTool.sby]!.version, 'SBY v0.70');
    expect(report[FormalTool.yosys]!.found, isTrue);
    expect(report[FormalTool.yosys]!.verific, isFalse);
    expect(report[FormalTool.yosysSlang]!.found, isTrue);
    expect(report[FormalTool.yicesSmt2]!.found, isTrue);
    expect(report[FormalTool.eqy]!.found, isFalse);
    expect(report[FormalTool.z3]!.found, isFalse);
    expect(report.ready, isTrue, reason: 'sby and yosys answered');
    expect(report.missing, contains(FormalTool.eqy));
    expect(report.tools.map((t) => t.tool), FormalTool.values);
  });

  test('a Yosys that runs `verific -cfg` was built with Verific', () async {
    final script = _Script({
      'yosys -V': _ok('Yosys 0.70 (Tabby)'),
      'yosys -q -p verific -cfg': _ok('verific options'),
    });
    final report = await FormalToolchainProbe(
      runner: script.call,
      platform: RiscvHostPlatform.linux,
    ).probe();
    expect(report[FormalTool.yosys]!.verific, isTrue);
    expect(report.ready, isFalse, reason: 'sby is missing');
  });

  test('a Settings path for sby makes the other tools come from beside '
      'it', () async {
    final bin = Directory(p.join(tmp.path, 'oss-cad-suite', 'bin'))
      ..createSync(recursive: true);
    for (final name in ['sby', 'yosys', 'eqy']) {
      File(p.join(bin.path, name)).writeAsStringSync('');
    }
    final sby = p.join(bin.path, 'sby');
    final yosys = p.join(bin.path, 'yosys');
    final script = _Script({
      '$sby --version': _ok('SBY v0.70'),
      '$yosys -V': _ok('Yosys 0.70'),
    });
    final report = await FormalToolchainProbe(
      runner: script.call,
      platform: RiscvHostPlatform.linux,
    ).probe(sbyPath: bin.path);
    expect(report[FormalTool.sby]!.binary, sby);
    expect(report[FormalTool.yosys]!.binary, yosys);
    expect(report[FormalTool.eqy]!.binary, p.join(bin.path, 'eqy'));
    expect(
      report[FormalTool.z3]!.binary,
      'z3',
      reason: 'not beside sby, so looked up on PATH',
    );
    expect(script.calls, contains('$yosys -q -m slang -p help read_slang'));
  });

  test('a tool that cannot start, exits non-zero or prints nothing is '
      'missing', () async {
    final script = _Script({
      'sby --version': (exitCode: 0, lines: const <String>[]),
      'yosys -V': _fail,
    });
    final report = await FormalToolchainProbe(
      runner: script.call,
      platform: RiscvHostPlatform.linux,
    ).probe();
    expect(report[FormalTool.sby]!.found, isFalse);
    expect(report[FormalTool.yosys]!.found, isFalse);
    expect(report[FormalTool.yosys]!.verific, isNull);
    expect(report[FormalTool.bitwuzla]!.found, isFalse);
  });

  test('the guidance is phrased for each platform', () {
    for (final platform in RiscvHostPlatform.values) {
      final probe = FormalToolchainProbe(
        runner: (_, _) async => null,
        platform: platform,
      );
      final text = probe.guidanceFor(FormalTool.sby);
      expect(text, contains('OSS CAD Suite'), reason: platform.name);
      expect(text, isNot(contains('→')), reason: 'speakable');
    }
    final mac = FormalToolchainProbe(
      runner: (_, _) async => null,
      platform: RiscvHostPlatform.macos,
    );
    expect(mac.guidanceFor(FormalTool.sby), contains('Finder'));
    final windows = FormalToolchainProbe(
      runner: (_, _) async => null,
      platform: RiscvHostPlatform.windows,
    );
    expect(windows.guidanceFor(FormalTool.z3), contains('WSL2'));
    expect(windows.guidanceFor(FormalTool.z3), contains('only by the jobs'));
  });

  test('the real runner reports a program that does not exist as missing, '
      'without throwing', () async {
    expect(
      await FormalToolchainProbe.defaultRunner(
        p.join(tmp.path, 'no-such-sby'),
        const ['--version'],
      ),
      isNull,
    );
  });
}
