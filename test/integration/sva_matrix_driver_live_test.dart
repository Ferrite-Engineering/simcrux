// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@Tags(['integration', 'oss-cad-live'])
library;

// The 51-probe SVA matrix through SbyDriver against a real SymbiYosys, on
// both open frontends: every probe a frontend refuses lands in Did
// not run with the SVA diagnostic, a temporal probe in its hand-expected
// construct class; no probe that errors in the frontend is ever reported
// passing; no accepted probe is reported dropped.
//
// With SVA_MATRIX_RESULTS set, it also writes what each frontend did
// (probe, frontend, exit, cells) for
// `dart run tool/generate_sva_support_table.dart --check --results <file>`,
// which the engine canary runs to keep the docs-site table measured.
//
// Needs an OSS CAD Suite build with yosys-slang: OSS_CAD_SUITE, or its bin/
// on PATH. Skips without one, unless FORMAL_LIVE_REQUIRED=1.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/formal_bucket.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/formal_config.dart';
import 'package:simcrux/domain/models/formal_result_summary.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/simulator/sby_driver.dart';

import '../support/formal_fixture_checks.dart';

bool get _required => Platform.environment['FORMAL_LIVE_REQUIRED'] == '1';

final String? _sby = () {
  final suite = Platform.environment['OSS_CAD_SUITE'];
  if (suite != null && suite.isNotEmpty) {
    final sby = p.join(suite, 'bin', 'sby');
    return File(sby).existsSync() ? sby : null;
  }
  final which = Process.runSync(Platform.isWindows ? 'where' : 'which', [
    'sby',
  ]);
  if (which.exitCode != 0) return null;
  final first = (which.stdout as String).split('\n').first.trim();
  return first.isEmpty ? null : first;
}();

void main() {
  late Directory root;
  setUpAll(() => root = Directory.systemTemp.createTempSync('sva_matrix_'));
  tearDownAll(() => root.deleteSync(recursive: true));

  test(
    'every probe through SbyDriver: refused means Did not run with the '
    'diagnostic, never a pass',
    () async {
      final sby = _sby;
      if (sby == null) {
        const reason = 'sby not found; set OSS_CAD_SUITE or put it on PATH';
        if (_required) fail('FORMAL_LIVE_REQUIRED=1 and $reason');
        markTestSkipped(reason);
        return;
      }
      final yosys = p.join(p.dirname(sby), 'yosys');
      if (Process.runSync(yosys, [
            '-Q',
            '-q',
            '-p',
            'plugin -i slang',
          ]).exitCode !=
          0) {
        if (_required) fail('FORMAL_LIVE_REQUIRED=1 and no yosys-slang');
        markTestSkipped('this build has no yosys-slang plugin');
        return;
      }
      final expected = readJsonObject(
        p.join(kFormalFixtureRoot, 'sva_matrix', 'sva_matrix.expected.json'),
      );
      final problems = <String>[];
      final results = StringBuffer('probe\tfrontend\texit\tcells\n');
      for (final probe in objectList(expected['probes'])) {
        final name = probe['probe']! as String;
        final source = File(
          p.absolute(kFormalFixtureRoot, 'sva_matrix', 'probes', '$name.sv'),
        );
        expect(source.existsSync(), isTrue, reason: source.path);
        final text = source.readAsStringSync();
        final cover = RegExp(r'\bcover\b').hasMatch(text);
        for (final fe in kFormalSvaFrontends) {
          final dir = Directory(
            p.join(root.path, name.replaceAll('/', '_'), fe),
          )..createSync(recursive: true);
          File(p.join(dir.path, 'probe.sv')).writeAsStringSync(text);
          final read = fe == 'builtin'
              ? 'read_verilog -formal -sv probe.sv'
              : 'plugin -i slang\nread_slang probe.sv --top m';
          File(p.join(dir.path, 'probe.sby')).writeAsStringSync(
            '[options]\nmode ${cover ? 'cover' : 'bmc'}\ndepth 2\n\n'
            '[engines]\nsmtbmc yices\n\n[script]\n$read\nprep -top m\n\n'
            '[files]\nprobe.sv\n',
          );
          final work = Directory(p.join(dir.path, 'work'))..createSync();
          final done =
              (await SbyDriver()
                      .execute(
                        ExecuteRequest(
                          test: TestSpec(
                            id: 'sva/$name/$fe',
                            name: name,
                            suiteName: 'sva',
                            simulatorId: SbyDriver.kId,
                            top: 'm',
                            formal: FormalConfig(
                              sbyFile: p.join(dir.path, 'probe.sby'),
                              sbyBinary: sby,
                              projectRoot: dir.path,
                            ),
                          ),
                          workingDirectory: work.path,
                          compileResult: null,
                          binaryConfig: const SimulatorBinaryConfig(
                            simulatorId: SbyDriver.kId,
                          ),
                        ),
                      )
                      .toList())
                  .whereType<TestExecutionFinished>()
                  .single;
          final summary = FormalResultSummary.fromMetrics(done.metrics);
          final verdict = done.metrics['formal.verdict'];
          final refused = verdict == 'ERROR';
          results.writeln('$name\t$fe\t${refused ? 1 : 0}\t');
          final where = '$name ($fe)';
          if (refused && done.status == TestStatus.pass) {
            problems.add('$where: refused, but reported passing');
          }
          if (refused && summary?.bucket != FormalBucket.didNotRun) {
            problems.add('$where: refused, but not Did not run');
          }
          switch (probe[fe]) {
            case 'refuse' when !refused:
              problems.add('$where: documented as refused, ran ($verdict)');
            case 'accept' when refused:
              problems.add('$where: documented as accepted, refused');
          }
          if (refused) {
            final want = probe['class'] as String? ?? 'other';
            if (done.metrics['formal.not_run_reason'] != 'sva_unsupported') {
              problems.add('$where: refused with no SVA diagnostic');
            } else if (done.metrics['formal.sva.class'] != want) {
              problems.add(
                '$where: class ${done.metrics['formal.sva.class']}, '
                'expected $want',
              );
            }
            if (done.metrics['formal.frontend'] != fe) {
              problems.add(
                '$where: frontend ${done.metrics['formal.frontend']}',
              );
            }
          } else if (done.metrics['formal.not_run_reason'] == 'dropped') {
            problems.add('$where: an accepted probe was reported dropped');
          }
        }
      }
      final out = Platform.environment['SVA_MATRIX_RESULTS'];
      if (out != null && out.isNotEmpty) {
        File(out).writeAsStringSync(results.toString());
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
