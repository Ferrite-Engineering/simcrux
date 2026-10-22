// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/enums/waveform_capture_policy.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/flow/flow_metric_keys.dart';
import 'package:simcrux/services/flow/gate_level/gls_outcome.dart';
import 'package:simcrux/services/flow/gate_level/gls_result.dart';
import 'package:simcrux/services/flow/gate_level/gls_run_info.dart';
import 'package:simcrux/services/flow/gate_level/gls_runner.dart';
import 'package:simcrux/services/job_scheduler/gls_scratch.dart';

import '../../../support/gls_support.dart';

const String _gl = kGlFixtures;

typedef _FakeInner = FakeGlsInner;

GlsAnswer _ok() => glsPass();

void main() {
  late Directory tmp;
  late String run;
  late GlsScratch scratch;

  /// A LibreLane run directory for the research MAC: `resolved.json` naming
  /// the design source and the (fake) cell models, and `final/nl` holding
  /// [netlist] as `dut.nl.v`.
  Future<GlsRunInfo> macRun({
    String netlist = 'net.v',
    String kind = 'nl',
    Map<String, Object?> extra = const <String, Object?>{},
    bool withModels = true,
  }) async {
    writeMacRun(
      run: run,
      pdkParent: tmp.path,
      netlist: netlist,
      kind: kind,
      extra: extra,
      withModels: withModels,
    );
    final result = await GlsRunInfo.read(
      runRoot: run,
      netlist: kind,
      flowRunId: 'flow-run-1',
    );
    return result.info!;
  }

  TestSpec macTest({
    String name = 'plain',
    String simulator = 'icarus',
    int? seed = 7,
    Map<String, String> defines = const <String, String>{},
    Map<String, String> parameters = const <String, String>{},
    List<String>? sources,
  }) => TestSpec(
    id: 'mac/$name',
    name: name,
    suiteName: 'mac',
    simulatorId: simulator,
    top: 'tb',
    sources:
        sources ??
        <String>[p.absolute('$_gl/mac/dut.v'), p.absolute('$_gl/mac/tb.v')],
    defines: <String, String>{'OUT': '"mac.txt"', ...defines},
    parameters: parameters,
    seed: seed,
  );

  Future<GlsPlanSet> plan(
    GlsRunInfo info,
    List<TestSpec> tests, {
    GlsOptions options = const GlsOptions(),
  }) async {
    final runDir = await scratch.allocateRun('r1');
    return await GlsPlanner.plan(
      info: info,
      options: options,
      selected: tests,
      runDir: runDir,
      scratch: scratch,
    );
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('gls_runner_');
    run = p.join(tmp.path, 'run');
    Directory(run).createSync();
    scratch = GlsScratch(root: p.join(tmp.path, 'scratch'));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('selection', () {
    final a = macTest(name: 'alpha');
    final b = macTest(name: 'beta');

    test('a test is named by its name or its id, in project order', () {
      final got = GlsPlanner.select(
        <TestSpec>[a, b],
        <String>[
          'mac/beta',
          'alpha',
        ],
      );
      expect(got.selected, <TestSpec>[a, b]);
      expect(got.unmatched, isEmpty);
    });

    test('a selector that names nothing is returned, not guessed at', () {
      final got = GlsPlanner.select(
        <TestSpec>[a, b],
        <String>[
          'alpha',
          'nope',
          'tag:smoke',
        ],
      );
      expect(got.selected, <TestSpec>[a]);
      expect(got.unmatched, <String>['nope', 'tag:smoke']);
    });

    test('no selectors select nothing', () {
      final got = GlsPlanner.select(<TestSpec>[a, b], const <String>[]);
      expect(got.selected, isEmpty);
    });
  });

  group('the derived specs', () {
    test('the gate spec keeps the testbench and swaps the design for the '
        'netlist and the models', () async {
      final info = await macRun();
      final set = await plan(info, <TestSpec>[macTest()]);
      final gate = set.plans.single.gateSpec!;
      final bench = p.absolute('$_gl/mac/tb.v');
      expect(gate.sources.first, bench);
      expect(gate.sources, isNot(contains(p.absolute('$_gl/mac/dut.v'))));
      expect(
        gate.sources.map(p.basename),
        containsAllInOrder(<String>[
          'tb.v',
          'gls_portdump.v',
          'primitives.v',
          'sky130_fd_sc_hd.v',
          'dut.nl.v',
        ]),
      );
      expect(gate.sources.last, info.netlistPath);
      expect(gate.defines['FUNCTIONAL'], '1');
      expect(gate.defines['UNIT_DELAY'], '#1');
      expect(gate.extraTops, <String>['gls_portdump']);
      expect(gate.top, 'tb');
      expect(gate.id, 'gls/mac/plain');
      expect(gate.suiteName, 'gls');
    });

    test('the RTL rerun is the same test with the same dump module', () async {
      final info = await macRun();
      final original = macTest();
      final set = await plan(info, <TestSpec>[original]);
      final rtl = set.plans.single.rtlSpec!;
      expect(rtl.sources.take(2), original.sources);
      expect(rtl.sources.last, endsWith('gls_portdump.v'));
      expect(rtl.defines, original.defines);
      expect(rtl.defines.containsKey('FUNCTIONAL'), isFalse);
      expect(rtl.extraTops, <String>['gls_portdump']);
    });

    test('the simulator, seed, defines and parameters are copied, never '
        'chosen, for every test and both simulators', () async {
      final info = await macRun();
      for (final simulator in <String>['icarus', 'verilator']) {
        final original = macTest(
          simulator: simulator,
          seed: 31,
          defines: <String, String>{'DEPTH': '8'},
          parameters: <String, String>{'W': '16'},
        );
        final set = await plan(info, <TestSpec>[original]);
        final one = set.plans.single;
        final rtl = one.rtlSpec!;
        final gate = one.gateSpec!;
        // One simulator for the pair, and it is Icarus, whatever the RTL
        // test ran under: a pair split across two simulators cannot be built.
        expect(rtl.simulatorId, gate.simulatorId, reason: simulator);
        expect(gate.simulatorId, 'icarus', reason: simulator);
        expect(rtl.seed, original.seed);
        expect(gate.seed, original.seed);
        expect(rtl.parameters, original.parameters);
        expect(gate.parameters, original.parameters);
        for (final entry in original.defines.entries) {
          expect(rtl.defines[entry.key], entry.value);
          expect(gate.defines[entry.key], entry.value);
        }
        expect(gate.timeout, original.timeout);
        expect(gate.passFail, original.passFail);
        expect(gate.resources, original.resources);
        expect(rtl.waveform.capture, WaveformCapturePolicy.never);
        expect(gate.waveform.capture, WaveformCapturePolicy.never);
      }
    });

    test('the one place a simulator is chosen maps Verilator to Icarus and '
        'refuses the rest', () {
      expect(glsSimulatorIdFor('icarus'), 'icarus');
      expect(glsSimulatorIdFor('verilator'), 'icarus');
      expect(glsSimulatorIdFor('ghdl'), isNull);
      expect(glsSimulatorIdFor('cocotb'), isNull);
      expect(glsSimulatorIdFor('sby'), isNull);
    });

    test('a power-aware netlist adds the supply tie and its define', () async {
      final info = await macRun(kind: 'pnl');
      expect(info.powerAware, isTrue);
      final set = await plan(
        info,
        <TestSpec>[macTest()],
        options: const GlsOptions(netlist: 'pnl'),
      );
      final gate = set.plans.single.gateSpec!;
      expect(gate.defines['USE_POWER_PINS'], '1');
      expect(gate.extraTops, <String>['gls_portdump', 'gls_power']);
      expect(gate.sources.map(p.basename), contains('gls_power.v'));
      final tie = File(
        gate.sources.firstWhere((s) => s.endsWith('gls_power.v')),
      ).readAsStringSync();
      expect(tie, contains("force tb.uut.VPWR = 1'b1;"));
      expect(tie, contains("force tb.uut.VGND = 1'b0;"));
      final nl = (await plan(await macRun(), <TestSpec>[
        macTest(),
      ])).plans.single.gateSpec!;
      expect(nl.defines.containsKey('USE_POWER_PINS'), isFalse);
      expect(nl.extraTops, <String>['gls_portdump']);
    });

    test('the dump module lists the DUT ports under the instance scope, '
        'and the supply is not among them', () async {
      final info = await macRun();
      final set = await plan(info, <TestSpec>[macTest()]);
      final one = set.plans.single;
      expect(one.scope, 'tb.uut');
      expect(one.clock, 'clk');
      expect(one.ports, <String>[
        'clk',
        'rst_n',
        'en',
        'a',
        'b',
        'acc',
        'cnt',
        'parity',
      ]);
      final text = File(
        one.gateSpec!.sources.firstWhere((s) => s.endsWith('gls_portdump.v')),
      ).readAsStringSync();
      expect(text, contains('module gls_portdump;'));
      expect(text, contains(r'$dumpfile("'));
      expect(text, contains('tb.uut.acc'));
      expect(text, contains('tb.uut.parity'));
      expect(text, isNot(contains('VPWR')));
    });

    test("generated files live only in SimCrux's own scratch", () async {
      final info = await macRun();
      final set = await plan(info, <TestSpec>[macTest()]);
      final one = set.plans.single;
      for (final path in <String>[
        one.rtlVcd!,
        one.gateVcd!,
        ...one.gateSpec!.sources.where((s) => p.basename(s).startsWith('gls_')),
        ...one.rtlSpec!.sources.where((s) => p.basename(s).startsWith('gls_')),
      ]) {
        expect(p.isWithin(scratch.root, path), isTrue, reason: path);
        expect(p.isWithin(run, path), isFalse, reason: path);
      }
    });
  });

  group('tests that cannot run', () {
    test('a VHDL test is skipped with rtl_language', () async {
      final info = await macRun();
      final set = await plan(info, <TestSpec>[
        macTest(simulator: 'ghdl'),
        macTest(name: 'mixed', sources: <String>['rtl/a.vhd', 'tb.v']),
      ]);
      expect(set.plans.map((p) => p.skip), <GlsNotRunReason?>[
        GlsNotRunReason.rtlLanguage,
        GlsNotRunReason.rtlLanguage,
      ]);
    });

    test('a simulator gate level does not use is named', () async {
      final info = await macRun();
      final set = await plan(info, <TestSpec>[macTest(simulator: 'cocotb')]);
      expect(set.plans.single.skip, GlsNotRunReason.simulatorUnsupported);
    });

    test('a test none of whose sources the run synthesised', () async {
      final info = await macRun();
      final set = await plan(info, <TestSpec>[
        macTest(sources: <String>[p.absolute('$_gl/mac/tb.v')]),
      ]);
      expect(set.plans.single.skip, GlsNotRunReason.noDesignSources);
    });

    test('a netlist that split its ports is port_shape, before any '
        'simulator runs', () async {
      final info = await macRun(netlist: 'net_splitports.v');
      final set = await plan(info, <TestSpec>[macTest()]);
      expect(set.plans.single.skip, GlsNotRunReason.portShape);
      expect(set.plans.single.gateSpec, isNull);
    });

    test('missing cell models skip every test, naming the file', () async {
      final info = await macRun(withModels: false);
      final set = await plan(info, <TestSpec>[macTest()]);
      expect(set.plans.single.skip, GlsNotRunReason.modelsMissing);
    });

    test('a testbench that does not instantiate the design', () async {
      final info = await macRun();
      File(p.join(tmp.path, 'other_tb.v')).writeAsStringSync(
        'module tb; endmodule\n',
      );
      final set = await plan(info, <TestSpec>[
        macTest(
          sources: <String>[
            p.absolute('$_gl/mac/dut.v'),
            p.join(tmp.path, 'other_tb.v'),
          ],
        ),
      ]);
      expect(set.plans.single.skip, GlsNotRunReason.dutScope);
    });

    test('a run with no netlist of the kind asked for', () async {
      await macRun();
      final result = await GlsRunInfo.read(runRoot: run, netlist: 'pnl');
      expect(result.problem, GlsNotRunReason.netlistMissing);
      expect(result.info, isNull);
      expect(
        (await GlsRunInfo.read(runRoot: p.join(tmp.path, 'absent'))).problem,
        GlsNotRunReason.runUnreadable,
      );
    });
  });

  group('the clock', () {
    test('the entry names it, else the run records it, else a single '
        'clock-like input, else the user picks', () async {
      final info = await macRun();
      Future<GlsPlan> go(GlsOptions o) async =>
          (await plan(info, <TestSpec>[macTest()], options: o)).plans.single;
      expect((await go(const GlsOptions(clock: 'clk'))).clock, 'clk');
      expect((await go(const GlsOptions())).clock, 'clk');
      final named = await go(const GlsOptions(clock: 'rst_n'));
      expect(named.clock, 'rst_n', reason: 'a named input is honoured');
      final notInput = await go(const GlsOptions(clock: 'parity'));
      expect(notInput.skip, GlsNotRunReason.clockUnknown);
      final missing = await go(const GlsOptions(clock: 'nope'));
      expect(missing.skip, GlsNotRunReason.clockUnknown);
    });

    test('with no recorded clock and one candidate, that one; with none, '
        'or with several, the entry must name it', () async {
      final noClock = await macRun(
        extra: <String, Object?>{'CLOCK_PORT': null},
      );
      final one = await plan(noClock, <TestSpec>[macTest()]);
      expect(one.plans.single.clock, 'clk');
      // A netlist whose inputs hold two clock-like names.
      File(p.join(run, 'final', 'nl', 'dut.nl.v')).writeAsStringSync('''
module dut (clk_a, clk_b, d, q);
  input clk_a;
  input clk_b;
  input d;
  output q;
endmodule
''');
      final two = await plan(noClock, <TestSpec>[macTest()]);
      expect(two.plans.single.skip, GlsNotRunReason.clockAmbiguous);
      expect(two.plans.single.skipDetail, 'clk_a, clk_b');
      File(p.join(run, 'final', 'nl', 'dut.nl.v')).writeAsStringSync('''
module dut (d, q);
  input d;
  output q;
endmodule
''');
      final none = await plan(noClock, <TestSpec>[macTest()]);
      expect(none.plans.single.skip, GlsNotRunReason.clockUnknown);
    });
  });

  group('the wrapper over a scheduler', () {
    /// Runs every planned test of [tests] through a [GlsScheduler] over
    /// [inner] and returns the finished results, in order.
    Future<List<TestResult>> runAll(
      _FakeInner inner,
      GlsRunInfo info,
      List<TestSpec> tests, {
      GlsOptions options = const GlsOptions(),
    }) async {
      final set = await plan(info, tests, options: options);
      final scheduler = GlsScheduler(
        inner: inner,
        plans: set.plans,
        info: info,
        options: options,
      );
      final results = <TestResult>[];
      var finished = false;
      await for (final e in scheduler.submit(
        RegressionRequest(
          runId: 'gls-run',
          tests: <TestSpec>[for (final one in set.plans) one.submitSpec],
          concurrency: 2,
        ),
      )) {
        if (e is TestFinished) results.add(e.result);
        if (e is RegressionFinished) finished = true;
      }
      expect(finished, isTrue);
      return results;
    }

    /// Writes the MAC port dumps a real Icarus would have written.
    void Function(TestSpec) dumps(
      GlsPlanSet? Function() planned, {
      required String rtl,
      required String gate,
    }) => (spec) {
      for (final one in planned()!.plans) {
        if (spec.id == one.rtlSpec?.id) {
          File('$_gl/mac/vcd/$rtl.vcd').copySync(one.rtlVcd!);
        } else if (spec.id == one.gateSpec?.id) {
          File('$_gl/mac/vcd/$gate.vcd').copySync(one.gateVcd!);
        }
      }
    };

    Future<({_FakeInner inner, GlsRunInfo info, GlsPlanSet set})> macSetup({
      required String rtl,
      required String gate,
      List<TestSpec>? tests,
      GlsOptions options = const GlsOptions(),
      ({TestStatus status, String? failure, List<String> logs, bool executed})
      Function(TestSpec spec)?
      answer,
    }) async {
      final info = await macRun();
      final set = await plan(
        info,
        tests ?? <TestSpec>[macTest()],
        options: options,
      );
      final inner = _FakeInner(
        answer ?? (_) => _ok(),
        onRun: dumps(() => set, rtl: rtl, gate: gate),
      );
      return (inner: inner, info: info, set: set);
    }

    Future<List<TestResult>> exec(
      ({_FakeInner inner, GlsRunInfo info, GlsPlanSet set}) s, {
      GlsOptions options = const GlsOptions(),
    }) async {
      final scheduler = GlsScheduler(
        inner: s.inner,
        plans: s.set.plans,
        info: s.info,
        options: options,
      );
      final results = <TestResult>[];
      await for (final e in scheduler.submit(
        RegressionRequest(
          runId: 'gls-run',
          tests: <TestSpec>[for (final one in s.set.plans) one.submitSpec],
          concurrency: 2,
        ),
      )) {
        if (e is TestFinished) results.add(e.result);
      }
      return results;
    }

    test('X-asymmetry only: the gate passes, the RTL x is classified, and '
        'the counts are in the metrics', () async {
      final s = await macSetup(rtl: 'rtl_x', gate: 'gate_x');
      final result = (await exec(s)).single;
      final view = GlsResultView.of(result)!;
      expect(view.outcome, GlsOutcome.xOnly);
      expect(view.realDiffs, 0);
      expect(view.xDiffs, greaterThanOrEqualTo(199));
      expect(view.firstDiffPs, isNotNull);
      expect(view.netlist, 'nl');
      expect(view.simulator, 'icarus');
      expect(view.flowRunId, 'flow-run-1');
      expect(view.scope, 'tb.uut');
      expect(view.clock, 'clk');
      expect(view.passes, isTrue);
      expect(result.status, TestStatus.pass);
      expect(result.testId, 'gls/mac/plain');
      expect(result.metrics[GlsMetricKeys.delays], 'functional');
      expect(result.waveformPath, endsWith('ports.vcd'));
      expect(result.metrics[FlowMetricKeys.runDir], isNull);
      expect(s.inner.submitted, hasLength(2));
      expect(s.inner.submitted.first.id, 'gls-rtl/mac/plain');
      expect(s.inner.submitted.last.id, 'gls/mac/plain');
    });

    test('strict x turns an X-only result into a failing test', () async {
      const options = GlsOptions(strictX: true);
      final s = await macSetup(
        rtl: 'rtl_x',
        gate: 'gate_x',
        options: options,
      );
      final result = (await exec(s, options: options)).single;
      expect(GlsResultView.of(result)!.outcome, GlsOutcome.xOnly);
      expect(result.status, TestStatus.fail);
      expect(GlsResultView.of(result)!.passes, isFalse);
    });

    test('identical dumps are equal', () async {
      final s = await macSetup(rtl: 'verilator_rtl', gate: 'verilator_rtl');
      final view = GlsResultView.of((await exec(s)).single)!;
      expect(view.outcome, GlsOutcome.equal);
      expect(view.realDiffs, 0);
      expect(view.xDiffs, 0);
      expect(view.firstDiffPs, isNull);
    });

    test('a testbench that fails at gate level differs, whatever the '
        'dumps say', () async {
      final s = await macSetup(
        rtl: 'verilator_rtl',
        gate: 'verilator_rtl',
        answer: (spec) => spec.id.startsWith('gls-rtl')
            ? _ok()
            : (
                status: TestStatus.fail,
                failure: 'mismatch at 40 ns',
                logs: const <String>[],
                executed: true,
              ),
      );
      final result = (await exec(s)).single;
      expect(GlsResultView.of(result)!.outcome, GlsOutcome.differs);
      expect(result.status, TestStatus.fail);
      expect(result.failureMessage, contains('mismatch'));
    });

    test('a test that fails at RTL is not rerun at gate level', () async {
      final s = await macSetup(
        rtl: 'rtl',
        gate: 'gate',
        answer: (_) => (
          status: TestStatus.fail,
          failure: 'assertion at 10 ns',
          logs: const <String>[],
          executed: true,
        ),
      );
      final result = (await exec(s)).single;
      final view = GlsResultView.of(result)!;
      expect(view.outcome, GlsOutcome.notRun);
      expect(view.reason, GlsNotRunReason.failsAtRtl);
      expect(s.inner.submitted, hasLength(1));
      expect(result.status, TestStatus.fail);
      expect(result.didExecute, isFalse);
    });

    test('an RTL that does not compile, and a gate port that does not '
        'bind, are told apart', () async {
      final rtlBuild = await macSetup(
        rtl: 'rtl',
        gate: 'gate',
        answer: (_) => (
          status: TestStatus.fail,
          failure: 'compile failed: tb.sv:3: syntax error',
          logs: const <String>['tb.sv:3: syntax error'],
          executed: true,
        ),
      );
      expect(
        GlsResultView.of((await exec(rtlBuild)).single)!.reason,
        GlsNotRunReason.rtlBuildFailed,
      );
      final shape = await macSetup(
        rtl: 'rtl',
        gate: 'gate',
        answer: (spec) => spec.id.startsWith('gls-rtl')
            ? _ok()
            : (
                status: TestStatus.fail,
                failure: 'compile failed: tb.v:9: error',
                logs: const <String>[
                  "tb.v:9: error: port ``a'' is not a port of uut.",
                ],
                executed: true,
              ),
      );
      final view = GlsResultView.of((await exec(shape)).single)!;
      expect(view.reason, GlsNotRunReason.portShape);
      final other = await macSetup(
        rtl: 'rtl',
        gate: 'gate',
        answer: (spec) => spec.id.startsWith('gls-rtl')
            ? _ok()
            : (
                status: TestStatus.fail,
                failure: 'compile failed: unknown module sky130_xyz',
                logs: const <String>['unknown module sky130_xyz'],
                executed: true,
              ),
      );
      expect(
        GlsResultView.of((await exec(other)).single)!.reason,
        GlsNotRunReason.gateBuildFailed,
      );
      final unbound = await macSetup(
        rtl: 'rtl',
        gate: 'gate',
        answer: (_) => (
          status: TestStatus.fail,
          failure: 'compile failed: gls_portdump.v:5: error',
          logs: const <String>[
            "gls_portdump.v:5: error: Unable to bind wire/reg/memory `tb.uut.a' in `gls_portdump'",
          ],
          executed: true,
        ),
      );
      expect(
        GlsResultView.of((await exec(unbound)).single)!.reason,
        GlsNotRunReason.portShape,
      );
    });

    test('a simulator that is not installed is tool_missing', () async {
      final s = await macSetup(
        rtl: 'rtl',
        gate: 'gate',
        answer: (_) => (
          status: TestStatus.fail,
          failure: 'icarus binary `iverilog` not available (system).',
          logs: const <String>[],
          executed: false,
        ),
      );
      expect(
        GlsResultView.of((await exec(s)).single)!.reason,
        GlsNotRunReason.toolMissing,
      );
    });

    test('a dump that is not there is vcd_unreadable, not an equal', () async {
      final info = await macRun();
      final set = await plan(info, <TestSpec>[macTest()]);
      final inner = _FakeInner((_) => _ok());
      final result = (await exec((inner: inner, info: info, set: set))).single;
      final view = GlsResultView.of(result)!;
      expect(view.outcome, GlsOutcome.notRun);
      expect(view.reason, GlsNotRunReason.vcdUnreadable);
    });

    test('tests that could not be planned still get their row and say '
        'why', () async {
      final info = await macRun();
      final set = await plan(info, <TestSpec>[
        macTest(simulator: 'ghdl'),
        macTest(name: 'ok'),
      ]);
      final inner = _FakeInner(
        (_) => _ok(),
        onRun: dumps(() => set, rtl: 'verilator_rtl', gate: 'verilator_rtl'),
      );
      final results = await exec((inner: inner, info: info, set: set));
      final byId = <String, GlsResultView>{
        for (final r in results) r.testId: GlsResultView.of(r)!,
      };
      expect(byId['gls/mac/plain']!.reason, GlsNotRunReason.rtlLanguage);
      expect(byId['gls/mac/ok']!.outcome, GlsOutcome.equal);
      expect(
        inner.submitted.map((s) => s.id),
        isNot(contains('gls/mac/plain')),
      );
    });

    test('cancelling reaches the scheduler holding the run and ends the '
        'rest as cancelled', () async {
      final info = await macRun();
      final set = await plan(info, <TestSpec>[
        macTest(name: 'a'),
        macTest(name: 'b'),
      ]);
      final inner = _FakeInner((_) => _ok());
      final scheduler = GlsScheduler(
        inner: inner,
        plans: set.plans,
        info: info,
        options: const GlsOptions(),
      );
      await scheduler.cancel('gls-run');
      final events = await scheduler
          .submit(
            RegressionRequest(
              runId: 'gls-run',
              tests: <TestSpec>[for (final one in set.plans) one.submitSpec],
            ),
          )
          .toList();
      final results = <TestResult>[
        for (final e in events)
          if (e is TestFinished) e.result,
      ];
      expect(results.map((r) => r.status), everyElement(TestStatus.cancelled));
      expect(events.last, isA<RegressionFinished>());
      expect((events.last as RegressionFinished).cancelled, isTrue);
      expect(inner.submitted, isEmpty);
    });

    test(
      'the run completes with a final event and a finished status',
      () async {
        final s = await macSetup(rtl: 'verilator_rtl', gate: 'verilator_rtl');
        final results = await runAll(s.inner, s.info, <TestSpec>[macTest()]);
        expect(results, hasLength(1));
      },
    );
  });

  group('the metrics view', () {
    test('a result that is not gate level has no view', () {
      final now = DateTime.now().toUtc();
      expect(
        GlsResultView.of(
          TestResult(
            testId: 'a',
            runId: 'r',
            status: TestStatus.pass,
            startedAt: now,
            finishedAt: now,
          ),
        ),
        isNull,
      );
    });

    test('the run telemetry is six closed properties and no counts', () {
      final now = DateTime.now().toUtc();
      TestResult r(String outcome, {String? real}) => TestResult(
        testId: 'gls/$outcome',
        runId: 'r',
        status: TestStatus.pass,
        startedAt: now,
        finishedAt: now,
        metrics: <String, String>{
          GlsMetricKeys.outcome: outcome,
          GlsMetricKeys.netlist: 'nl',
          GlsMetricKeys.delays: 'functional',
          GlsMetricKeys.simulator: 'icarus',
          GlsMetricKeys.target: 'sky130',
          GlsMetricKeys.realDiffs: real ?? '0',
          GlsMetricKeys.xDiffs: '12',
        },
      );
      final props = glsRunCompletedProperties(<TestResult>[
        r('equal'),
        r('x_only'),
      ], clamp: (n) => n)!;
      expect(props.keys, <String>[
        'outcome',
        'simulator',
        'netlist',
        'delays',
        'target',
        'tests',
      ]);
      expect(props['outcome'], 'x_only');
      expect(props['tests'], 2);
      expect(
        glsRunCompletedProperties(<TestResult>[
          r('equal'),
          r('differs', real: '3'),
        ], clamp: (n) => n)!['outcome'],
        'differs',
      );
      expect(
        glsRunCompletedProperties(<TestResult>[
          r('not_run'),
        ], clamp: (n) => n)!['outcome'],
        'not_run',
      );
      expect(
        glsRunCompletedProperties(const <TestResult>[], clamp: (n) => n),
        isNull,
      );
    });
  });

  group('the scratch', () {
    test('keeps the newest runs and removes only its own older ones', () async {
      final s = GlsScratch(root: p.join(tmp.path, 'keep'), keepRuns: 2);
      final a = await s.allocateRun('a');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final b = await s.allocateRun('b');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final foreign = Directory(p.join(s.root, 'not_ours'))..createSync();
      final c = await s.allocateRun('c');
      expect(Directory(a).existsSync(), isFalse);
      expect(Directory(b).existsSync(), isTrue);
      expect(Directory(c).existsSync(), isTrue);
      expect(foreign.existsSync(), isTrue, reason: 'only gls- directories');
    });

    test('a run id that is already there gets a fresh directory', () async {
      final s = GlsScratch(root: p.join(tmp.path, 'dup'), keepRuns: 5);
      final one = await s.allocateRun('same');
      final two = await s.allocateRun('same');
      expect(one, isNot(two));
      expect(GlsScratch.segmentFor('a/b c'), 'gls-a_b_c');
    });
  });
}
