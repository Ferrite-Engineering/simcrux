// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:args/args.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/core/cli/flow_cli.dart';
import 'package:simcrux/core/cli/gls_cli_extension.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/services/flow/gate_level/gls_result.dart';
import 'package:simcrux/services/flow/gate_level/gls_run_info.dart';
import 'package:simcrux/services/flow/gate_level/gls_runner.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

import '../../support/gls_support.dart';

/// An edition's `flow gls` extension, scripted: records each call.
class _Extension implements GlsCliExtension {
  _Extension({this.refuse, this.delayFile});

  final int? refuse;
  final String? delayFile;
  final List<String> calls = <String>[];
  List<GlsResultView> reported = const <GlsResultView>[];

  @override
  void addOptions(ArgParser parser) =>
      parser.addFlag('extra', negatable: false);

  @override
  bool appliesTo(ArgResults results) => results.flag('extra');

  @override
  Future<int?> admit(ArgResults results) async {
    calls.add('admit');
    return refuse;
  }

  @override
  Future<GlsCliPrepared> prepare(
    ArgResults results,
    GlsRunInfo info,
    GlsOptions options,
  ) async {
    calls.add('prepare');
    return GlsCliPrepared.run(
      GlsOptions(
        netlist: options.netlist,
        strictX: options.strictX,
        clock: options.clock,
        tests: options.tests,
        delayFile: delayFile,
      ),
    );
  }

  @override
  JobScheduler wrapInner(JobScheduler inner) {
    calls.add('wrap');
    return inner;
  }

  @override
  Future<int> report({
    required ArgResults results,
    required GlsRunInfo info,
    required List<TestResult> finished,
    required List<GlsResultView> views,
    int? interrupted,
  }) async {
    calls.add('report');
    reported = views;
    return 42;
  }
}

void main() {
  late Directory tmp;
  late String run;
  late String project;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('flow_gls_ext_');
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
''');
    writeMacRun(run: run, pdkParent: tmp.path);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<({int code, FakeGlsInner inner, List<String> out})> gls(
    _Extension? extension,
    List<String> args,
  ) async {
    final out = <String>[];
    final inner = FakeGlsInner(
      (_) => glsPass(),
      onRun: glsVcdWriter(rtl: 'rtl_x', gate: 'gate_x'),
    );
    final code =
        await FlowCli(
          stdoutSink: out.add,
          stderrSink: (_) {},
          driverRegistry: SimulatorDriverRegistry(const {}),
          schedulerFactory: (_) => inner,
          glsScratchRoot: () => p.join(tmp.path, 'scratch'),
          environment: () => <String, String>{'HOME': tmp.path},
          glsExtension: extension,
        ).run(<String>[
          'gls',
          run,
          '--project',
          project,
          '--test',
          'plain',
          ...args,
        ]);
    return (code: code, inner: inner, out: out);
  }

  test('without its flag the extension is never called and the functional '
      'simulation runs as it does without one', () async {
    final extension = _Extension();
    final r = await gls(extension, <String>['--json']);
    expect(r.code, 0);
    expect(extension.calls, isEmpty);
    expect(r.inner.submitted.last.extraCompileArgs, isEmpty);
  });

  test('with its flag: admitted, prepared, wrapped and reported, in that '
      'order, and the options it prepared are the ones that run', () async {
    final sdf = p.join(run, 'final', 'sdf', 'nom', 'dut__nom.sdf');
    Directory(p.dirname(sdf)).createSync(recursive: true);
    File(sdf).writeAsStringSync('(DELAYFILE)\n');
    final extension = _Extension(delayFile: sdf);
    final r = await gls(extension, <String>['--extra']);
    expect(r.code, 42);
    expect(extension.calls, <String>['admit', 'prepare', 'wrap', 'report']);
    expect(
      r.inner.submitted.last.extraCompileArgs,
      GlsPlanner.delayCompileArgs,
    );
    expect(extension.reported.single.annotated, isTrue);
    expect(r.out, isEmpty, reason: 'the extension writes its own report');
  });

  test('a refusal at admission ends the command with its code before any '
      'project, run or engine work', () async {
    final extension = _Extension(refuse: 77);
    final r = await gls(extension, <String>['--extra']);
    expect(r.code, 77);
    expect(extension.calls, <String>['admit']);
    expect(r.inner.submitted, isEmpty);
  });

  test(
    'a malformed line is usage, 64, before the extension is asked',
    () async {
      final extension = _Extension(refuse: 77);
      final r = await gls(extension, <String>['--extra', '--bogus']);
      expect(r.code, 64);
      expect(extension.calls, isEmpty);
    },
  );
}
