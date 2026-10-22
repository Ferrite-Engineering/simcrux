// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Live: `simcrux flow gls` end to end against the real Icarus and the real
// sky130 cell models, on LibreLane-shaped run directories built here around
// the committed gate-level fixtures. The expectations come from the RTL's and
// the testbenches' meaning (see the fixtures' PROVENANCE.md), never from
// SimCrux's own output:
//
// - the research MAC's RTL is x until its first clock edge where the gate
//   flops are already reset, and under the `x*0` probe `parity` stays x at RTL
//   while the gates compute 0: X-asymmetry only, never a real difference;
// - a register the RTL initialises and the cell does not reset is a real
//   difference at its first sample, whatever the testbench says;
// - a netlist whose ports the testbench cannot bind is `port_shape`, with and
//   without bit-split port names;
// - a Verilator test's gate-level request runs both runs under Icarus.
//
// Gated on the toolchain: OSS_CAD_SUITE (a directory holding bin/) and a ciel
// or volare install of sky130 with its cell models (PDK_ROOT, or ~/.ciel).
// FLOW_LIVE_REQUIRED=1 turns a missing tool or PDK into a failure. Tagged
// `oss-cad-live`, which the CI Test job excludes and flow-live.yml runs.

@Tags(['oss-cad-live'])
@Timeout(Duration(minutes: 20))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/core/cli/flow_cli.dart';
import 'package:simcrux/core/cli/simcrux_cli.dart';
import 'package:simcrux/services/config/config_loader.dart';

const _gl = 'verification/fixtures/flow/gate_level';
const _adderRun = 'verification/fixtures/flow/librelane/3.0.16/sky130A_met/run';

bool get _required => Platform.environment['FLOW_LIVE_REQUIRED'] == '1';

String? get _suiteBin {
  final suite = Platform.environment['OSS_CAD_SUITE'];
  if (suite == null || suite.isEmpty) return null;
  return p.join(suite, 'bin');
}

/// The versioned sky130 PDK directory that holds the cell models, from
/// `PDK_ROOT` or `~/.ciel` or `~/.volare`, or null.
String? _pdkRoot() {
  final home = Platform.environment['HOME'] ?? '';
  final bases = <String>[
    ?Platform.environment['PDK_ROOT'],
    p.join(home, '.ciel'),
    p.join(home, '.volare'),
  ];
  for (final base in bases) {
    for (final manager in const <String>['ciel', 'volare']) {
      final versions = Directory(p.join(base, manager, 'sky130', 'versions'));
      if (!versions.existsSync()) continue;
      for (final v in versions.listSync().whereType<Directory>()) {
        final models = File(
          p.join(
            v.path,
            'sky130A',
            'libs.ref',
            'sky130_fd_sc_hd',
            'verilog',
            'sky130_fd_sc_hd.v',
          ),
        );
        if (models.existsSync()) return v.path;
      }
    }
  }
  return null;
}

String? _blocker() {
  final bin = _suiteBin;
  if (bin == null) return 'OSS_CAD_SUITE is unset';
  for (final tool in const ['iverilog', 'vvp']) {
    if (!File(p.join(bin, tool)).existsSync()) return '$tool missing in $bin';
  }
  if (_pdkRoot() == null) return 'no sky130 PDK with cell models found';
  return null;
}

void main() {
  final blocker = _blocker();
  if (blocker != null && _required) {
    test('the live toolchain is installed', () => fail(blocker));
  }

  group('flow gls against the real Icarus and the real cell models', () {
    late Directory tmp;
    late String pdk;
    late String bin;

    setUpAll(() {
      tmp = Directory.systemTemp.createTempSync('flow_gls_live_');
      pdk = _pdkRoot()!;
      bin = _suiteBin!;
    });
    tearDownAll(() => tmp.deleteSync(recursive: true));

    String models(String file) => p.join(
      pdk,
      'sky130A',
      'libs.ref',
      'sky130_fd_sc_hd',
      'verilog',
      file,
    );

    /// A LibreLane-shaped run directory: `resolved.json` naming the design
    /// source, the clock and the real cell models, and `final/<kind>/`
    /// holding [netlist] as the design's netlist.
    String run(
      String name, {
      required String design,
      required String netlist,
      required String designSource,
    }) {
      final root = Directory(p.join(tmp.path, 'runs', name))
        ..createSync(recursive: true);
      Directory(p.join(root.path, 'final', 'nl')).createSync(recursive: true);
      File(netlist).copySync(
        p.join(root.path, 'final', 'nl', '$design.nl.v'),
      );
      File(p.join(root.path, 'resolved.json')).writeAsStringSync(
        jsonEncode(<String, Object?>{
          'PDK': 'sky130A',
          'STD_CELL_LIBRARY': 'sky130_fd_sc_hd',
          'DESIGN_NAME': design,
          'CLOCK_PORT': 'clk',
          'PDK_ROOT': pdk,
          'VERILOG_POWER_DEFINE': 'USE_POWER_PINS',
          'VERILOG_FILES': <String>[p.absolute(designSource)],
          'CELL_VERILOG_MODELS': <String>[
            models('primitives.v'),
            models('sky130_fd_sc_hd.v'),
          ],
        }),
      );
      return root.path;
    }

    /// A project holding [tests] (YAML, one suite `gls_live`), with Icarus
    /// taken from the suite.
    String project(String name, String tests) {
      final dir = Directory(p.join(tmp.path, 'proj_$name'))..createSync();
      final file = File(p.join(dir.path, 'simcrux.yaml'))
        ..writeAsStringSync('''
version: "1"
simulators:
  icarus:
    source: custom
    path: $bin
suites:
  gls_live:
    tests:
$tests
''');
      return file.path;
    }

    FlowCli cli(List<String> out, List<String> err) => FlowCli(
      stdoutSink: out.add,
      stderrSink: err.add,
      driverRegistry: SimcruxCli.defaultDriverRegistry(),
      loaderFactory: ({required allowTooling}) =>
          ConfigLoader(allowProjectDefinedTooling: true),
      glsScratchRoot: () => p.join(tmp.path, 'scratch'),
    );

    Future<({int code, Map<String, dynamic> json, List<String> err})> gls(
      String runDir,
      String projectFile,
      List<String> args,
    ) async {
      final out = <String>[];
      final err = <String>[];
      final code = await cli(out, err).run(<String>[
        'gls',
        runDir,
        '--project',
        projectFile,
        '--json',
        ...args,
      ]);
      return (
        code: code,
        json: jsonDecode(out.join('\n')) as Map<String, dynamic>,
        err: err,
      );
    }

    Map<String, dynamic> test0(Map<String, dynamic> json, String id) =>
        (json['tests'] as List).cast<Map<String, dynamic>>().singleWhere(
          (t) => t['test_id'] == id,
        );

    String macTests({String simulator = 'icarus', String extra = ''}) {
      final mac = p.absolute('$_gl/mac');
      return '''
      - name: plain
        simulator: $simulator
        top: tb
        sources: [$mac/dut.v, $mac/tb.v]
        defines: {OUT: '"plain.txt"'}
      - name: probe
        simulator: $simulator
        top: tb
        sources: [$mac/dut.v, $mac/tb.v]
        defines: {OUT: '"probe.txt"', XPROBE: "1"}
$extra''';
    }

    test('the research MAC: X-asymmetry only, never a real difference, and '
        'the x*0 probe is X-asymmetric on 199 cycles', () async {
      final runDir = run(
        'mac',
        design: 'dut',
        netlist: '$_gl/mac/net.v',
        designSource: '$_gl/mac/dut.v',
      );
      final r = await gls(runDir, project('mac', macTests()), <String>[
        '--test',
        'plain',
        '--test',
        'probe',
      ]);
      expect(r.code, 0, reason: r.err.join('\n'));
      final plain = test0(r.json, 'gls/gls_live/plain');
      expect(plain['outcome'], 'x_only');
      expect(plain['real_diffs'], 0);
      expect(plain['x_diffs'], greaterThanOrEqualTo(1));
      expect(plain['simulator'], 'icarus');
      expect(plain['netlist'], 'nl');
      expect(plain['delays'], 'functional');
      final probe = test0(r.json, 'gls/gls_live/probe');
      expect(probe['outcome'], 'x_only');
      expect(probe['real_diffs'], 0);
      expect(probe['x_diffs'], greaterThanOrEqualTo(199));
      expect(r.json['exit_label'], 'met');
    });

    test('strict x fails an X-only test with exit 1', () async {
      final runDir = run(
        'mac_strict',
        design: 'dut',
        netlist: '$_gl/mac/net.v',
        designSource: '$_gl/mac/dut.v',
      );
      final r = await gls(runDir, project('mac_strict', macTests()), <String>[
        '--test',
        'probe',
        '--strict-x',
      ]);
      expect(r.code, 1);
      expect(test0(r.json, 'gls/gls_live/probe')['outcome'], 'x_only');
      expect(test0(r.json, 'gls/gls_live/probe')['passes'], isFalse);
    });

    test(
      'a Verilator test reruns its RTL and its gate run under Icarus',
      () async {
        final runDir = run(
          'mac_vl',
          design: 'dut',
          netlist: '$_gl/mac/net.v',
          designSource: '$_gl/mac/dut.v',
        );
        final r = await gls(
          runDir,
          project('mac_vl', macTests(simulator: 'verilator')),
          <String>['--test', 'plain'],
        );
        expect(r.code, 0, reason: r.err.join('\n'));
        final plain = test0(r.json, 'gls/gls_live/plain');
        expect(plain['simulator'], 'icarus');
        expect(plain['outcome'], 'x_only');
        expect(plain['real_diffs'], 0);
      },
    );

    test(
      'a register the RTL initialises and the cell does not reset is a '
      'real difference at its first sample, though the testbench passes',
      () async {
        final rl = p.absolute('$_gl/resetless');
        final runDir = run(
          'resetless',
          design: 'rl',
          netlist: '$rl/rl.nl.v',
          designSource: '$rl/rl.v',
        );
        final r = await gls(
          runDir,
          project('resetless', '''
      - name: reg
        simulator: icarus
        top: tb
        sources: [$rl/rl.v, $rl/tb.v]
'''),
          <String>['--test', 'reg'],
        );
        expect(r.code, 1, reason: r.err.join('\n'));
        final t = test0(r.json, 'gls/gls_live/reg');
        expect(t['outcome'], 'differs');
        expect(t['real_diffs'], 1);
        expect(t['first_diff_ps'], 10000);
      },
    );

    test('a netlist the testbench cannot bind is port_shape, exit 2, with '
        'bit-split names and with a renamed port', () async {
      final split = await gls(
        run(
          'mac_split',
          design: 'dut',
          netlist: '$_gl/mac/net_splitports.v',
          designSource: '$_gl/mac/dut.v',
        ),
        project('mac_split', macTests()),
        <String>['--test', 'plain'],
      );
      expect(split.code, 2);
      expect(test0(split.json, 'gls/gls_live/plain')['outcome'], 'not_run');
      expect(test0(split.json, 'gls/gls_live/plain')['reason'], 'port_shape');

      final rl = p.absolute('$_gl/resetless');
      final renamed = await gls(
        run(
          'resetless_renamed',
          design: 'rl',
          netlist: '$rl/rl_renamed.nl.v',
          designSource: '$rl/rl.v',
        ),
        project('resetless_renamed', '''
      - name: reg
        simulator: icarus
        top: tb
        sources: [$rl/rl.v, $rl/tb.v]
'''),
        <String>['--test', 'reg'],
      );
      expect(renamed.code, 2);
      expect(test0(renamed.json, 'gls/gls_live/reg')['reason'], 'port_shape');
    });

    test('a test that fails at RTL is not rerun at gate level', () async {
      final rl = p.absolute('$_gl/resetless');
      final broken = File(p.join(tmp.path, 'broken_tb.v'))
        ..writeAsStringSync(
          File('$_gl/resetless/tb.v').readAsStringSync().replaceFirst(
            'expect_q = i[0];',
            'expect_q = ~i[0];',
          ),
        );
      final r = await gls(
        run(
          'resetless_failing',
          design: 'rl',
          netlist: '$rl/rl.nl.v',
          designSource: '$rl/rl.v',
        ),
        project('resetless_failing', '''
      - name: reg
        simulator: icarus
        top: tb
        sources: [$rl/rl.v, ${broken.path}]
        pass_fail:
          type: exit_code
'''),
        <String>['--test', 'reg'],
      );
      // The testbench prints ERROR: and $finish: Icarus exits 0, and the
      // driver reads the ERROR: line as the failure.
      expect(r.code, 2);
      expect(test0(r.json, 'gls/gls_live/reg')['reason'], 'fails_at_rtl');
    });

    test('the committed adder run and its self-checking testbench: equal, '
        'x for ever on both sides', () async {
      final design = Directory(
        'verification/fixtures/flow/librelane/designs/path_adder',
      ).absolute.path;
      final resolved =
          jsonDecode(File('$_adderRun/resolved.json').readAsStringSync())
              as Map<String, dynamic>;
      final text = jsonEncode(resolved)
          .replaceAll(
            RegExp(r'<home>/\.ciel/ciel/sky130/versions/[0-9a-f]+'),
            pdk.replaceAll(r'\', r'\\'),
          )
          .replaceAll('<design>', design.replaceAll(r'\', r'\\'));
      final root = Directory(p.join(tmp.path, 'runs', 'adder'))
        ..createSync(recursive: true);
      Directory(p.join(root.path, 'final', 'nl')).createSync(recursive: true);
      File('$_adderRun/final/nl/path_adder.nl.v').copySync(
        p.join(root.path, 'final', 'nl', 'path_adder.nl.v'),
      );
      File(p.join(root.path, 'resolved.json')).writeAsStringSync(text);
      final tb = p.absolute('$_gl/path_adder/tb_path_adder.v');
      final r = await gls(
        root.path,
        project('adder', '''
      - name: adder
        simulator: icarus
        top: tb
        sources: [$design/path_adder.v, $tb]
'''),
        <String>['--test', 'adder'],
      );
      expect(r.code, 0, reason: r.err.join('\n'));
      final t = test0(r.json, 'gls/gls_live/adder');
      expect(t['outcome'], 'equal');
      expect(t['real_diffs'], 0);
      expect(t['x_diffs'], 0);
    });

    test('nothing is written under the run, and nothing is synthesised', () {
      for (final run in Directory(
        p.join(tmp.path, 'runs'),
      ).listSync().whereType<Directory>()) {
        final names = run
            .listSync(recursive: true)
            .whereType<File>()
            .map((f) => p.relative(f.path, from: run.path))
            .toSet();
        final allowed = <String>{
          'resolved.json',
          p.join('final', 'nl', 'dut.nl.v'),
          p.join('final', 'nl', 'rl.nl.v'),
          p.join('final', 'nl', 'path_adder.nl.v'),
        };
        expect(
          names.difference(allowed),
          isEmpty,
          reason: '${run.path} holds files SimCrux wrote',
        );
      }
    });
  }, skip: blocker);
}
