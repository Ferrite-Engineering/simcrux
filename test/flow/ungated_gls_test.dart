// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:crux_license/crux_license_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/core/cli/flow_cli.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

import '../support/gls_support.dart';

/// Gate-level simulation is never gated. At Open Core with the beta period
/// over and no Pro overrides, `simcrux flow gls` runs, classifies and exits:
/// every outcome and both counts are in `--json`, `--junit` and the text, and
/// the exit code follows the outcome. Nothing on these paths consults a
/// licence. The results table and the inspector render the outcome and both
/// counts at Open Core with the beta period over in
/// `test/features/flow/gls_results_table_test.dart`, whose harness pins both.
///
/// No simulator runs here: a scripted scheduler answers the RTL and the gate
/// run, and writes the research MAC's port dumps for the comparator to read.
void main() {
  late Directory tmp;
  late String run;
  late String project;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('flow_gls_ungated_');
    run = p.join(tmp.path, 'run');
    Directory(run).createSync();
    final mac = p.absolute('$kGlFixtures/mac');
    project = p.join(tmp.path, 'simcrux.yaml');
    File(project).writeAsStringSync('''
version: "1"
suites:
  mac:
    tests:
      - name: plain
        simulator: icarus
        top: tb
        sources: [$mac/dut.v, $mac/tb.v]
        defines: {OUT: '"mac.txt"'}
      - name: other
        simulator: verilator
        top: tb
        sources: [$mac/dut.v, $mac/tb.v]
        defines: {OUT: '"other.txt"'}
''');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  FlowCli cli(
    List<String> out,
    List<String> err, {
    required FakeGlsInner inner,
  }) => FlowCli(
    stdoutSink: out.add,
    stderrSink: err.add,
    driverRegistry: SimulatorDriverRegistry(const {}),
    schedulerFactory: (_) => inner,
    glsScratchRoot: () => p.join(tmp.path, 'scratch'),
    environment: () => <String, String>{'HOME': tmp.path},
  );

  /// Runs `flow gls` over [run], with [args] after the project.
  Future<({int code, List<String> out, List<String> err})> gls(
    List<String> args, {
    FakeGlsInner? inner,
    String? runDir,
  }) async {
    final out = <String>[];
    final err = <String>[];
    final code = await cli(
      out,
      err,
      inner:
          inner ??
          FakeGlsInner(
            (_) => glsPass(),
            onRun: glsVcdWriter(rtl: 'rtl_x', gate: 'gate_x'),
          ),
    ).run(<String>['gls', runDir ?? run, '--project', project, ...args]);
    return (code: code, out: out, err: err);
  }

  Map<String, dynamic> jsonOf(List<String> out) =>
      jsonDecode(out.join('\n')) as Map<String, dynamic>;

  test('runs at Open Core with kBetaPeriod false: X-asymmetry only passes, '
      'with both counts', () async {
    expect(kBetaPeriod, isFalse);
    writeMacRun(run: run, pdkParent: tmp.path);
    final r = await gls(<String>['--test', 'plain', '--json']);
    expect(r.code, 0, reason: r.err.join('\n'));
    final json = jsonOf(r.out);
    final t = (json['tests'] as List).single as Map<String, dynamic>;
    expect(t['test_id'], 'gls/mac/plain');
    expect(t['rtl_test'], 'mac/plain');
    expect(t['outcome'], 'x_only');
    expect(t['real_diffs'], 0);
    expect(t['x_diffs'], greaterThanOrEqualTo(199));
    expect(t['netlist'], 'nl');
    expect(t['delays'], 'functional');
    expect(t['simulator'], 'icarus');
    expect(t['strict_x'], isFalse);
    expect(t['passes'], isTrue);
    expect(json['schema'], 'simcrux-flow-gls/1');
    expect(json['exit_code'], 0);
    expect(json['exit_label'], 'met');
    expect(json['note'], contains('no timing checks'));
  });

  test('the text output names the outcome and both counts, and keeps '
      'results on stdout and diagnostics on stderr', () async {
    writeMacRun(run: run, pdkParent: tmp.path);
    final r = await gls(<String>['--test', 'plain']);
    expect(
      r.out.first,
      matches(RegExp(r'^gls/mac/plain: x_only {2}real 0, x-asymmetry \d+$')),
    );
    expect(r.out.last, 'simcrux flow gls: met');
    expect(r.err.where((l) => l.contains('met')), isEmpty);
  });

  test('strict x turns X-asymmetry only into exit 1', () async {
    writeMacRun(run: run, pdkParent: tmp.path);
    final r = await gls(<String>['--test', 'plain', '--strict-x', '--json']);
    expect(r.code, 1);
    final t = (jsonOf(r.out)['tests'] as List).single as Map<String, dynamic>;
    expect(t['outcome'], 'x_only');
    expect(t['passes'], isFalse);
    expect(t['strict_x'], isTrue);
  });

  test('a testbench that fails at gate level differs: exit 1', () async {
    writeMacRun(run: run, pdkParent: tmp.path);
    final inner = FakeGlsInner(
      (spec) => spec.id.startsWith('gls-rtl/')
          ? glsPass()
          : (
              status: TestStatus.fail,
              failure: 'mismatch',
              logs: const <String>[],
              executed: true,
            ),
      onRun: glsVcdWriter(rtl: 'verilator_rtl', gate: 'verilator_rtl'),
    );
    final r = await gls(<String>['--test', 'plain', '--json'], inner: inner);
    expect(r.code, 1);
    final t = (jsonOf(r.out)['tests'] as List).single as Map<String, dynamic>;
    expect(t['outcome'], 'differs');
  });

  test('equal dumps are equal: exit 0, zero counts', () async {
    writeMacRun(run: run, pdkParent: tmp.path);
    final inner = FakeGlsInner(
      (_) => glsPass(),
      onRun: glsVcdWriter(rtl: 'verilator_rtl', gate: 'verilator_rtl'),
    );
    final r = await gls(<String>['--test', 'plain', '--json'], inner: inner);
    expect(r.code, 0);
    final t = (jsonOf(r.out)['tests'] as List).single as Map<String, dynamic>;
    expect(t['outcome'], 'equal');
    expect(t['real_diffs'], 0);
    expect(t['x_diffs'], 0);
    expect(t['first_diff_ps'], isNull);
  });

  test('no test could run: exit 2, with the reason', () async {
    writeMacRun(run: run, pdkParent: tmp.path);
    final inner = FakeGlsInner(
      (_) => (
        status: TestStatus.fail,
        failure: 'assertion',
        logs: const <String>[],
        executed: true,
      ),
    );
    final r = await gls(<String>['--test', 'plain', '--json'], inner: inner);
    expect(r.code, 2);
    final t = (jsonOf(r.out)['tests'] as List).single as Map<String, dynamic>;
    expect(t['outcome'], 'not_run');
    expect(t['reason'], 'fails_at_rtl');
    expect(r.out.join('\n'), contains('"exit_label": "could_not_evaluate"'));
    expect(inner.submitted, hasLength(1));
  });

  test('a netlist with split ports is port_shape, exit 2, and no simulator '
      'is started', () async {
    writeMacRun(
      run: run,
      pdkParent: tmp.path,
      netlist: 'net_splitports.v',
    );
    final inner = FakeGlsInner((_) => glsPass());
    final r = await gls(<String>['--test', 'plain', '--json'], inner: inner);
    expect(r.code, 2);
    final t = (jsonOf(r.out)['tests'] as List).single as Map<String, dynamic>;
    expect(t['reason'], 'port_shape');
    expect(inner.submitted, isEmpty);
  });

  test('both runs of a Verilator test are Icarus runs', () async {
    writeMacRun(run: run, pdkParent: tmp.path);
    final inner = FakeGlsInner(
      (_) => glsPass(),
      onRun: glsVcdWriter(rtl: 'verilator_rtl', gate: 'verilator_rtl'),
    );
    final r = await gls(<String>['--test', 'other', '--json'], inner: inner);
    expect(r.code, 0);
    expect(inner.submitted.map((s) => s.simulatorId), <String>[
      'icarus',
      'icarus',
    ]);
    final t = (jsonOf(r.out)['tests'] as List).single as Map<String, dynamic>;
    expect(t['simulator'], 'icarus');
  });

  test('--junit carries the outcome and both counts, a failure for a '
      'difference and a skip for a test that did not run', () async {
    writeMacRun(run: run, pdkParent: tmp.path);
    final out = p.join(tmp.path, 'gls.xml');
    final r = await gls(<String>['--test', 'plain', '--junit', out]);
    expect(r.code, 0);
    final xml = File(out).readAsStringSync();
    expect(xml, contains('<testsuite name="simcrux-flow-gls" tests="1"'));
    expect(xml, contains('name="outcome" value="x_only"'));
    expect(xml, contains('name="real_diffs" value="0"'));
    expect(xml, contains('name="x_diffs" value='));
    expect(xml, isNot(contains('<failure')));

    final failing = await gls(
      <String>['--test', 'plain', '--strict-x', '--junit', out],
    );
    expect(failing.code, 1);
    expect(File(out).readAsStringSync(), contains('<failure type="x_only"'));

    final skipped = await gls(
      <String>['--test', 'plain', '--junit', out],
      inner: FakeGlsInner(
        (_) => (
          status: TestStatus.fail,
          failure: 'x',
          logs: const <String>[],
          executed: true,
        ),
      ),
    );
    expect(skipped.code, 2);
    final xml3 = File(out).readAsStringSync();
    expect(xml3, contains('skipped="1"'));
    expect(xml3, contains('did not run: fails_at_rtl'));
  });

  test(
    "the entry's gls: block supplies the tests, the netlist and strict x",
    () async {
      writeMacRun(run: run, pdkParent: tmp.path);
      Directory(p.join(tmp.path, 'librelane')).createSync();
      File(
        p.join(tmp.path, 'librelane', 'config.yaml'),
      ).writeAsStringSync('DESIGN_NAME: dut\n');
      final mac = p.absolute('$kGlFixtures/mac');
      File(project).writeAsStringSync('''
version: "1"
suites:
  mac:
    tests:
      - name: plain
        simulator: icarus
        top: tb
        sources: [$mac/dut.v, $mac/tb.v]
        defines: {OUT: '"mac.txt"'}
flow:
  entries:
    - name: counter
      kind: librelane
      config: librelane/config.yaml
      pdk: sky130A
      gls:
        tests: [plain]
        strict_x: true
''');
      final r = await gls(<String>['--json']);
      expect(r.code, 1, reason: r.err.join('\n'));
      final t = (jsonOf(r.out)['tests'] as List).single as Map<String, dynamic>;
      expect(t['test_id'], 'gls/mac/plain');
      expect(t['strict_x'], isTrue);
      expect(t['passes'], isFalse);
    },
  );

  group('the exit codes of a command line that cannot be honoured', () {
    test('a missing run directory, project, test name or test selection '
        'is usage, 64', () async {
      writeMacRun(run: run, pdkParent: tmp.path);
      expect(
        (await gls(<String>[
          '--test',
          'plain',
        ], runDir: p.join(tmp.path, 'x'))).code,
        64,
      );
      expect((await gls(<String>['--test', 'nope'])).code, 64);
      expect((await gls(<String>[])).code, 64);
      expect((await gls(<String>['--test', 'tag:smoke'])).code, 64);
      expect((await gls(<String>['--test', 'plain', '--bogus'])).code, 64);
      expect(
        (await gls(<String>['--test', 'plain', '--netlist', 'sdf'])).code,
        64,
      );
      expect(
        (await gls(<String>['--test', 'plain', '--entry', 'nope'])).code,
        64,
      );
      final out = <String>[];
      final err = <String>[];
      final noProject = await cli(
        out,
        err,
        inner: FakeGlsInner((_) => glsPass()),
      ).run(<String>['gls', run, '--project', p.join(tmp.path, 'none.yaml')]);
      expect(noProject, 64);
      expect(
        await cli(
          out,
          err,
          inner: FakeGlsInner((_) => glsPass()),
        ).run(<String>['gls']),
        64,
      );
    });

    test('a run record that cannot be read is data error, 65', () async {
      final r = await gls(<String>['--test', 'plain']);
      expect(r.code, 65);
      expect(r.err.join('\n'), contains('run_unreadable'));
    });

    test('a run without the netlist asked for is 2, and models that cannot '
        'be found are a did-not-run reason, 2', () async {
      writeMacRun(run: run, pdkParent: tmp.path);
      final pnl = await gls(<String>['--test', 'plain', '--netlist', 'pnl']);
      expect(pnl.code, 2);
      expect(pnl.err.join('\n'), contains('netlist_missing'));

      final bare = p.join(tmp.path, 'bare');
      Directory(bare).createSync();
      writeMacRun(run: bare, pdkParent: tmp.path, withModels: false);
      final r = await gls(<String>[
        '--test',
        'plain',
        '--json',
      ], runDir: bare);
      expect(r.code, 2);
      final t = (jsonOf(r.out)['tests'] as List).single as Map<String, dynamic>;
      expect(t['reason'], 'models_missing');
    });

    test('-h anywhere prints usage and exits 0 before any file or engine '
        'work', () async {
      final out = <String>[];
      final code = await cli(
        out,
        <String>[],
        inner: FakeGlsInner((_) => glsPass()),
      ).run(<String>['gls', '-h']);
      expect(code, 0);
      expect(out.join('\n'), contains('gls    <run-dir>'));
      expect(out.join('\n'), contains('2 no test could run'));
    });
  });

  test('no gate-level file reads the licence tier or the beta flag', () {
    final files = <File>[
      ...Directory(
        'lib/services/flow/gate_level',
      ).listSync().whereType<File>().where((f) => f.path.endsWith('.dart')),
      File('lib/services/job_scheduler/gls_scratch.dart'),
      File('lib/features/flow/gls_labels.dart'),
      File('lib/features/inspector/widgets/inspector_gls_notes.dart'),
    ];
    expect(files.length, greaterThan(8));
    for (final file in files) {
      final text = file.readAsStringSync();
      expect(text, isNot(contains('licenseTier')), reason: file.path);
      expect(text, isNot(contains('kBetaPeriod')), reason: file.path);
      expect(text, isNot(contains('FeatureGate')), reason: file.path);
    }
  });
}
