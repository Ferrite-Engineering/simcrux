// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Live: `simcrux flow run`, `gate` and `ingest` end to end against the real
// Yosys and nextpnr, on the committed path_adder RTL at the two frequencies
// the fixture set measures (12 MHz met, 1000 MHz violated). The expected
// verdicts are the fixtures' own hand-written verdict.expected.json.
//
// Gated like flow_nextpnr_live_test.dart: OSS_CAD_SUITE (a directory holding
// bin/) or the tools on PATH; FLOW_LIVE_REQUIRED=1 turns a missing toolchain
// into a failure. Tagged `oss-cad-live`, which the CI Test job excludes and
// flow-live.yml runs.

@Tags(['oss-cad-live'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/core/cli/flow_cli.dart';
import 'package:simcrux/core/cli/simcrux_cli.dart';
import 'package:simcrux/services/config/config_loader.dart';

const _fixtures = 'verification/fixtures/flow/nextpnr';

String? get _suiteBin {
  final suite = Platform.environment['OSS_CAD_SUITE'];
  if (suite != null && suite.isNotEmpty) return p.join(suite, 'bin');
  final which = Process.runSync('which', ['nextpnr-ice40']);
  if (which.exitCode != 0) return null;
  return p.dirname((which.stdout as String).trim());
}

String _expectedVerdict(String fixture) =>
    (jsonDecode(
              File(
                '$_fixtures/$fixture/verdict.expected.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>)['verdict']
        as String;

void main() {
  final bin = _suiteBin;
  final blocker = bin == null || !File(p.join(bin, 'yosys')).existsSync()
      ? 'no OSS CAD Suite: set OSS_CAD_SUITE or put nextpnr-ice40 on PATH'
      : null;
  if (blocker != null && Platform.environment['FLOW_LIVE_REQUIRED'] == '1') {
    test('the live toolchain is installed', () => fail(blocker));
  }

  group('flow run against the real tools', () {
    late Directory project;
    setUpAll(() {
      project = Directory.systemTemp.createTempSync('flow_live_proj_');
      File('$_fixtures/rtl/path_adder.v').copySync(
        p.join(project.path, 'path_adder.v'),
      );
      File(p.join(project.path, 'simcrux.yaml')).writeAsStringSync('''
version: "1"
simulators:
  nextpnr:
    source: custom
    path: $bin
flow:
  entries:
    - name: adder_met
      kind: nextpnr
      family: ice40
      device: up5k
      package: sg48
      top: path_adder
      sources: [path_adder.v]
      freq_mhz: 12
    - name: adder_violated
      kind: nextpnr
      family: ice40
      device: up5k
      package: sg48
      top: path_adder
      sources: [path_adder.v]
      freq_mhz: 1000
''');
    });
    tearDownAll(() => project.deleteSync(recursive: true));

    FlowCli cli(List<String> out) => FlowCli(
      stdoutSink: out.add,
      stderrSink: (_) {},
      driverRegistry: SimcruxCli.defaultDriverRegistry(),
      loaderFactory: ({required allowTooling}) =>
          ConfigLoader(allowProjectDefinedTooling: true),
    );

    test(
      'one met and one violated entry exit 1, each with its verdict',
      () async {
        final out = <String>[];
        final code = await cli(
          out,
        ).run(['run', '--json', p.join(project.path, 'simcrux.yaml')]);
        final json = jsonDecode(out.join('\n')) as Map<String, dynamic>;
        final verdicts = <String, String>{
          for (final e
              in (json['entries'] as List).cast<Map<String, dynamic>>())
            e['test_id'] as String:
                (e['metrics'] as Map<String, dynamic>)['flow.verdict']
                    as String,
        };
        expect(verdicts, <String, String>{
          'flow/adder_met': _expectedVerdict('path_ice40_met'),
          'flow/adder_violated': _expectedVerdict('path_ice40_violated'),
        });
        expect(code, 1);
      },
    );

    test('gate and ingest read the runs it left, read-only', () async {
      final runs = p.join(project.path, 'runs');
      final met = Directory(p.join(runs, 'adder_met')).listSync().single.path;
      final violated = Directory(
        p.join(runs, 'adder_violated'),
      ).listSync().single.path;
      expect(await cli(<String>[]).run(['gate', met]), 0);
      expect(await cli(<String>[]).run(['gate', violated]), 1);
      final listing = Directory(
        runs,
      ).listSync(recursive: true).map((e) => e.path).toList()..sort();
      expect(await cli(<String>[]).run(['ingest', runs]), 1);
      final after = Directory(
        runs,
      ).listSync(recursive: true).map((e) => e.path).toList()..sort();
      expect(after, listing);
    });
  }, skip: blocker);
}
