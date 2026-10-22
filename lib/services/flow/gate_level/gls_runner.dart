// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/enums/waveform_capture_policy.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/resource_lock.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/domain/models/waveform_policy.dart';
import 'package:simcrux/services/flow/flow_metric_keys.dart';
import 'package:simcrux/services/flow/gate_level/gls_netlist.dart';
import 'package:simcrux/services/flow/gate_level/gls_outcome.dart';
import 'package:simcrux/services/flow/gate_level/gls_run_info.dart';
import 'package:simcrux/services/flow/gate_level/gls_trace_comparator.dart';
import 'package:simcrux/services/flow/gate_level/pdk_cell_models.dart';
import 'package:simcrux/services/job_scheduler/gls_scratch.dart';

/// Runs a task off the UI isolate in the app, directly in the headless
/// binary.
typedef GlsBackgroundRunner =
    Future<T> Function<T>(FutureOr<T> Function() task);

/// The headless runner: the task runs here, bounded by [GlsVcdLimits].
Future<T> glsRunDirect<T>(FutureOr<T> Function() task) async => await task();

/// What the user asked of one gate-level simulation.
@immutable
class GlsOptions {
  /// Creates the options.
  const GlsOptions({
    this.netlist = 'nl',
    this.strictX = false,
    this.clock,
    this.tests = const <String>[],
  });

  /// `nl` (the default) or `pnl`.
  final String netlist;

  /// Whether X-asymmetry alone fails a test.
  final bool strictX;

  /// The clock input the comparison samples on, when the user names one.
  final String? clock;

  /// SimCrux test names to rerun (a test's name, or its full id).
  final List<String> tests;
}

/// The plan for one gate-level test: the derived specs, the generated files,
/// and where its two port dumps go, or the reason it cannot run.
@immutable
class GlsPlan {
  /// Creates a plan that runs.
  GlsPlan.run({
    required this.original,
    required this.gateId,
    required RtlGateSpecs specs,
    required this.scope,
    required this.clock,
    required this.rtlVcd,
    required this.gateVcd,
    required this.ports,
  }) : rtlSpec = specs.rtl,
       gateSpec = specs.gate,
       skip = null,
       skipDetail = null;

  /// Creates a plan that does not run.
  const GlsPlan.skipped({
    required this.original,
    required this.gateId,
    required GlsNotRunReason reason,
    this.skipDetail,
  }) : skip = reason,
       rtlSpec = null,
       gateSpec = null,
       scope = null,
       clock = null,
       rtlVcd = null,
       gateVcd = null,
       ports = const <String>[];

  /// The RTL test as the project declares it.
  final TestSpec original;

  /// The gate-level test's id: what the results table lists.
  final String gateId;

  /// The RTL rerun, with the port dump.
  final TestSpec? rtlSpec;

  /// The gate-level run: the testbench against the netlist and the models.
  final TestSpec? gateSpec;

  /// Why it does not run, when it does not.
  final GlsNotRunReason? skip;

  /// A short, fixed qualifier for [skip], never a path.
  final String? skipDetail;

  /// The DUT's instance in the testbench (`tb.uut`).
  final String? scope;

  /// The clock the comparison samples on.
  final String? clock;

  /// The RTL run's port dump.
  final String? rtlVcd;

  /// The gate run's port dump.
  final String? gateVcd;

  /// The ports the dump lists and the comparison reads.
  final List<String> ports;

  /// Whether the test runs.
  bool get runs => skip == null;

  /// The spec the regression runner is handed for this test: the gate-level
  /// spec when it runs, and a spec of the same identity when it does not, so
  /// a test that could not run still has its row and says why.
  TestSpec get submitSpec =>
      gateSpec ??
      original.copyWith(
        id: gateId,
        name: '${original.suiteName}/${original.name}',
        suiteName: GlsPlanner.suiteName,
        simulatorId: glsSimulatorIdFor(original.simulatorId) ?? 'icarus',
      );
}

/// The RTL rerun and the gate run of one test: always the same simulator,
/// seed, defines and parameters, by construction.
@immutable
class RtlGateSpecs {
  /// Creates the pair.
  const RtlGateSpecs({required this.rtl, required this.gate});

  /// The RTL rerun.
  final TestSpec rtl;

  /// The gate-level run.
  final TestSpec gate;
}

/// What [GlsPlanner.plan] decided.
@immutable
class GlsPlanSet {
  /// Creates the set.
  const GlsPlanSet({
    required this.plans,
    this.unmatched = const <String>[],
    this.info,
    this.runProblem,
  });

  /// One plan per selected test, in the order the project lists them.
  final List<GlsPlan> plans;

  /// Selectors that matched no test.
  final List<String> unmatched;

  /// The run being simulated, when it can be.
  final GlsRunInfo? info;

  /// Why the run cannot be simulated at all, when it cannot.
  final GlsNotRunReason? runProblem;
}

/// Turns the selected regression tests and a LibreLane run into the derived
/// specs a gate-level simulation runs.
///
/// **Nothing is chosen here that a test already decided.** The gate-level
/// spec keeps the test's testbench sources, its seed, its parameters, its
/// defines, its timeout and its pass/fail detector; the design sources the
/// run synthesised are replaced by the run's netlist and the PDK cell models;
/// the defines `FUNCTIONAL` and `UNIT_DELAY=#1` are added. The RTL rerun is
/// the same spec on the RTL, with the same generated port-dump module. Both
/// take their simulator from `glsSimulatorIdFor`, so a cross-simulator
/// comparison cannot be built. Nothing is synthesised or reshaped: a netlist
/// whose ports do not match the RTL top is `notRun{port_shape}`.
abstract final class GlsPlanner {
  /// The suite gate-level tests are listed under.
  static const String suiteName = 'gls';

  /// The id of the gate-level test that reruns [rtl].
  static String gateIdFor(TestSpec rtl) => '$suiteName/${rtl.id}';

  /// The id of the RTL rerun of [rtl].
  static String rtlRerunIdFor(TestSpec rtl) => 'gls-rtl/${rtl.id}';

  /// The tests in [candidates] that [selectors] name (a test's name or its
  /// full id, in project order), and the selectors that named none.
  ///
  /// A `tag:` selector names nothing: SimCrux tests carry no tags.
  static ({List<TestSpec> selected, List<String> unmatched}) select(
    List<TestSpec> candidates,
    List<String> selectors,
  ) {
    final selected = <TestSpec>[];
    final unmatched = <String>[];
    final hit = <String>{};
    for (final selector in selectors) {
      var any = false;
      for (final spec in candidates) {
        if (spec.name == selector || spec.id == selector) {
          any = true;
          hit.add(spec.id);
        }
      }
      if (!any) unmatched.add(selector);
    }
    for (final spec in candidates) {
      if (hit.contains(spec.id)) selected.add(spec);
    }
    return (selected: selected, unmatched: unmatched);
  }

  /// Plans one gate-level simulation of [selected] against [info].
  ///
  /// Writes the generated port-dump modules (and the supply tie for a
  /// power-aware netlist) into [runDir], a directory from [GlsScratch], one
  /// subdirectory per test. Reads the netlist's port list and each
  /// testbench's sources on [background].
  static Future<GlsPlanSet> plan({
    required GlsRunInfo info,
    required GlsOptions options,
    required List<TestSpec> selected,
    required String runDir,
    required GlsScratch scratch,
    GlsBackgroundRunner background = glsRunDirect,
  }) async {
    final models = info.models;
    if (!models.ok) {
      return GlsPlanSet(
        plans: <GlsPlan>[
          for (final s in selected)
            GlsPlan.skipped(
              original: s,
              gateId: gateIdFor(s),
              reason: GlsNotRunReason.modelsMissing,
              skipDetail: models.problemDetail,
            ),
        ],
        info: info,
      );
    }
    final netlistPath = info.netlistPath;
    final design = info.design;
    final GlsNetlistPorts? netlistPorts;
    try {
      netlistPorts = await background(
        () => GlsNetlistPorts.read(netlistPath, design),
      );
    } on FileSystemException {
      return _allSkipped(info, selected, GlsNotRunReason.netlistMissing);
    }
    if (netlistPorts == null) {
      return _allSkipped(info, selected, GlsNotRunReason.runUnreadable);
    }
    final signalPorts = netlistPorts.signalPorts;
    final plans = <GlsPlan>[];
    var index = 0;
    for (final spec in selected) {
      index++;
      plans.add(
        await _planOne(
          spec: spec,
          index: index,
          info: info,
          options: options,
          netlistPorts: netlistPorts,
          signalPorts: signalPorts,
          runDir: runDir,
          scratch: scratch,
          background: background,
        ),
      );
    }
    return GlsPlanSet(plans: plans, info: info);
  }

  static GlsPlanSet _allSkipped(
    GlsRunInfo info,
    List<TestSpec> selected,
    GlsNotRunReason reason,
  ) => GlsPlanSet(
    plans: <GlsPlan>[
      for (final s in selected)
        GlsPlan.skipped(original: s, gateId: gateIdFor(s), reason: reason),
    ],
    info: info,
    runProblem: reason,
  );

  static bool _isVhdl(String path) {
    final ext = p.extension(path).toLowerCase();
    return ext == '.vhd' || ext == '.vhdl';
  }

  /// Whether [source] is one of the design sources the run synthesised: the
  /// same file, or (for a run from another machine) the same base name.
  static bool _isDesignSource(String source, List<String> designSources) {
    final path = p.normalize(p.absolute(source));
    String canonical(String file) {
      try {
        return File(file).resolveSymbolicLinksSync();
      } on FileSystemException {
        return file;
      }
    }

    final resolved = canonical(path);
    for (final design in designSources) {
      final other = p.normalize(design);
      if (!p.isAbsolute(other)) continue;
      // The same file, whether either side names it through a link.
      if (other == path || canonical(other) == resolved) return true;
    }
    // A run copied from another machine records that machine's paths. The
    // base name decides then, but only when the recorded file is not here.
    for (final design in designSources) {
      if (File(design).existsSync()) continue;
      if (p.basename(design) == p.basename(path)) return true;
    }
    return false;
  }

  static Future<GlsPlan> _planOne({
    required TestSpec spec,
    required int index,
    required GlsRunInfo info,
    required GlsOptions options,
    required GlsNetlistPorts netlistPorts,
    required List<GlsPort> signalPorts,
    required String runDir,
    required GlsScratch scratch,
    required GlsBackgroundRunner background,
  }) async {
    GlsPlan skip(GlsNotRunReason reason, [String? detail]) => GlsPlan.skipped(
      original: spec,
      gateId: gateIdFor(spec),
      reason: reason,
      skipDetail: detail,
    );

    if (spec.simulatorId == 'ghdl' || spec.sources.any(_isVhdl)) {
      return skip(GlsNotRunReason.rtlLanguage);
    }
    final simulator = glsSimulatorIdFor(spec.simulatorId);
    if (simulator == null) return skip(GlsNotRunReason.simulatorUnsupported);

    final bench = <String>[];
    var designFound = false;
    for (final source in spec.sources) {
      if (_isDesignSource(source, info.designSources)) {
        designFound = true;
      } else {
        bench.add(source);
      }
    }
    if (!designFound) return skip(GlsNotRunReason.noDesignSources);

    if (!netlistPorts.allUsable) return skip(GlsNotRunReason.portShape);

    final scopeResult = await background(
      () => GlsDutScope.find(
        sources: bench,
        testbenchTop: spec.top,
        design: info.design,
      ),
    );
    final scope = scopeResult.scope;
    if (scope == null) {
      return skip(GlsNotRunReason.dutScope, scopeResult.problem);
    }

    final clock = _clockFor(options, info, netlistPorts);
    if (clock.reason != null) {
      return skip(clock.reason!, clock.detail);
    }

    final testDir = await scratch.allocateTest(runDir, index);
    final rtlDir = p.join(testDir, 'rtl');
    final gateDir = p.join(testDir, 'gate');
    await Directory(rtlDir).create();
    await Directory(gateDir).create();
    final rtlVcd = p.join(rtlDir, 'ports.vcd');
    final gateVcd = p.join(gateDir, 'ports.vcd');
    final rtlDump = p.join(rtlDir, 'gls_portdump.v');
    final gateDump = p.join(gateDir, 'gls_portdump.v');
    final names = <String>[for (final port in signalPorts) port.name];
    await File(rtlDump).writeAsString(_dumpModule(scope.path, names, rtlVcd));
    await File(gateDump).writeAsString(_dumpModule(scope.path, names, gateVcd));
    final tops = <String>['gls_portdump'];
    final extraSources = <String>[gateDump];
    if (info.powerAware) {
      final tie = p.join(gateDir, 'gls_power.v');
      await File(tie).writeAsString(_powerModule(scope.path, info.supplyPins));
      tops.add('gls_power');
      extraSources.add(tie);
    }

    final specs = derive(
      original: spec,
      simulatorId: simulator,
      benchSources: bench,
      rtlDump: rtlDump,
      gateExtraSources: extraSources,
      gateExtraTops: tops,
      info: info,
    );
    return GlsPlan.run(
      original: spec,
      gateId: specs.gate.id,
      specs: specs,
      scope: scope.path,
      clock: clock.name,
      rtlVcd: rtlVcd,
      gateVcd: gateVcd,
      ports: names,
    );
  }

  /// The RTL rerun and the gate run derived from [original].
  ///
  /// Both are built from the one [simulatorId], and from [original]'s seed,
  /// parameters and defines, which are copied and never chosen: `$random(seed)`
  /// sequences differ between simulators, so a comparison across two of them
  /// is noise, and this function cannot produce one.
  @visibleForTesting
  static RtlGateSpecs derive({
    required TestSpec original,
    required String simulatorId,
    required List<String> benchSources,
    required String rtlDump,
    required List<String> gateExtraSources,
    required List<String> gateExtraTops,
    required GlsRunInfo info,
  }) {
    const quiet = WaveformPolicy(capture: WaveformCapturePolicy.never);
    final rtl = original.copyWith(
      id: rtlRerunIdFor(original),
      simulatorId: simulatorId,
      sources: <String>[...original.sources, rtlDump],
      waveform: quiet,
      extraTops: const <String>['gls_portdump'],
    );
    final gate = original.copyWith(
      id: gateIdFor(original),
      name: '${original.suiteName}/${original.name}',
      suiteName: suiteName,
      simulatorId: simulatorId,
      sources: <String>[
        ...benchSources,
        ...gateExtraSources,
        ...info.models.models,
        info.netlistPath,
      ],
      defines: <String, String>{
        ...original.defines,
        ...PdkCellModels.definesFor(info.models, powerAware: info.powerAware),
      },
      waveform: quiet,
      extraTops: gateExtraTops,
    );
    return RtlGateSpecs(rtl: rtl, gate: gate);
  }

  static ({String? name, GlsNotRunReason? reason, String? detail}) _clockFor(
    GlsOptions options,
    GlsRunInfo info,
    GlsNetlistPorts ports,
  ) {
    final inputs = <String>{for (final port in ports.inputs) port.name};
    final named = options.clock;
    if (named != null && named.isNotEmpty) {
      return inputs.contains(named)
          ? (name: named, reason: null, detail: null)
          : (
              name: null,
              reason: GlsNotRunReason.clockUnknown,
              detail: 'named_clock_not_an_input',
            );
    }
    final recorded = info.clockPort;
    if (recorded != null && inputs.contains(recorded)) {
      return (name: recorded, reason: null, detail: null);
    }
    final candidates = ports.clockCandidates;
    if (candidates.length == 1) {
      return (name: candidates.single, reason: null, detail: null);
    }
    return (
      name: null,
      reason: candidates.isEmpty
          ? GlsNotRunReason.clockUnknown
          : GlsNotRunReason.clockAmbiguous,
      detail: candidates.join(', '),
    );
  }

  /// The generated module that dumps the DUT's top-level ports to [vcd]: a
  /// second top, so the user's testbench is not edited.
  @visibleForTesting
  static String dumpModule(String scope, List<String> ports, String vcd) =>
      _dumpModule(scope, ports, vcd);

  static String _dumpModule(String scope, List<String> ports, String vcd) {
    final file = vcd.replaceAll(r'\', '/').replaceAll('"', '');
    final signals = ports.map((n) => '$scope.$n').join(',\n      ');
    return '''
// Generated for gate-level simulation. The testbench is not edited: this is a
// second top that dumps the design's top-level ports.
module gls_portdump;
  initial begin
    \$dumpfile("$file");
    \$dumpvars(0,
      $signals);
  end
endmodule
''';
  }

  /// The generated module that ties a power-aware netlist's supply from
  /// outside, a second top: without it the supply ports float and every
  /// output is x.
  @visibleForTesting
  static String powerModule(String scope, List<String> pins) =>
      _powerModule(scope, pins);

  static String _powerModule(String scope, List<String> pins) {
    final vdd = pins.isNotEmpty ? pins[0] : 'VPWR';
    final gnd = pins.length > 1 ? pins[1] : 'VGND';
    return '''
// Generated for gate-level simulation. Ties the power-aware netlist's supply
// from outside; neither the testbench nor the netlist is edited.
module gls_power;
  initial begin
    force $scope.$vdd = 1'b1;
    force $scope.$gnd = 1'b0;
  end
endmodule
''';
  }
}

/// Runs the planned gate-level tests: a [JobScheduler] that wraps a real one.
///
/// Each test is two runs through the wrapped scheduler, in order: the RTL
/// rerun with the generated port dump, then (only if the RTL passed) the gate
/// run. The testbench's own verdict at each is read exactly as SimCrux reads
/// it at RTL, by the scheduler's pass/fail detector; the two port dumps are
/// then compared, and the test's result is the gate run's with the
/// gate-level outcome and counts in its metrics.
///
/// Wrapping a scheduler (rather than driving the simulators directly) is what
/// puts the results through the regression runner's table, trend store and
/// telemetry unchanged: the submitted test ids are the gate-level ids, and
/// the stream is an ordinary [RegressionEvent] stream.
class GlsScheduler implements JobScheduler {
  /// Creates the scheduler over [inner].
  GlsScheduler({
    required this.inner,
    required Iterable<GlsPlan> plans,
    required this.info,
    required this.options,
    this.background = glsRunDirect,
    this.limits = GlsVcdLimits.standard,
  }) : _plans = <String, GlsPlan>{for (final plan in plans) plan.gateId: plan};

  /// The scheduler that runs the simulators.
  final JobScheduler inner;

  /// The run being simulated.
  final GlsRunInfo info;

  /// What the user asked.
  final GlsOptions options;

  /// Runs the VCD comparison: off the UI isolate in the app.
  final GlsBackgroundRunner background;

  /// Bounds on one port dump.
  final GlsVcdLimits limits;

  final Map<String, GlsPlan> _plans;
  final Set<String> _cancelled = <String>{};
  final Map<String, Set<String>> _active = <String, Set<String>>{};
  final Map<String, RegressionStatus> _status = <String, RegressionStatus>{};

  /// A message names a port-binding failure in either simulator run.
  static final RegExp kPortShapeMessage = RegExp(
    'is not a port of|Unable to bind wire/reg/memory',
  );

  @override
  Map<String, ResourceLock> get heldLocks => inner.heldLocks;

  @override
  RegressionStatus statusOf(String runId) =>
      _status[runId] ??
      RegressionStatus(
        runId: runId,
        totalTests: 0,
        completedTests: 0,
        runningTests: 0,
        isFinished: false,
      );

  @override
  Future<void> cancel(String runId) async {
    _cancelled.add(runId);
    for (final sub in List<String>.of(_active[runId] ?? const <String>{})) {
      await inner.cancel(sub);
    }
  }

  @override
  Stream<RegressionEvent> submit(RegressionRequest request) {
    final controller = StreamController<RegressionEvent>();
    unawaited(_run(request, controller));
    return controller.stream;
  }

  Future<void> _run(
    RegressionRequest request,
    StreamController<RegressionEvent> controller,
  ) async {
    final runId = request.runId;
    final tests = <GlsPlan>[
      for (final spec in request.tests) ?_plans[spec.id],
    ];
    var completed = 0;
    var running = 0;
    void publish({bool finished = false}) => _status[runId] = RegressionStatus(
      runId: runId,
      totalTests: tests.length,
      completedTests: completed,
      runningTests: running,
      isFinished: finished,
    );
    publish();
    final workers = request.concurrency < 1 ? 1 : request.concurrency;
    var next = 0;
    Future<void> worker() async {
      while (true) {
        if (next >= tests.length) return;
        final plan = tests[next++];
        if (_cancelled.contains(runId)) {
          controller.add(
            TestFinished(
              runId: runId,
              result: _notRun(
                plan,
                runId,
                GlsNotRunReason.cancelled,
                status: TestStatus.cancelled,
              ),
            ),
          );
          completed++;
          publish();
          continue;
        }
        running++;
        publish();
        try {
          await _test(request, plan, controller);
        } on Object catch (e) {
          controller.add(
            TestFinished(
              runId: runId,
              result: _notRun(
                plan,
                runId,
                GlsNotRunReason.gateBuildFailed,
                message: 'scheduler error: $e',
              ),
            ),
          );
        }
        running--;
        completed++;
        publish();
      }
    }

    try {
      await Future.wait(<Future<void>>[
        for (var i = 0; i < workers && i < tests.length; i++) worker(),
      ]);
    } finally {
      publish(finished: true);
      controller.add(
        RegressionFinished(
          runId: runId,
          cancelled: _cancelled.contains(runId),
        ),
      );
      await controller.close();
    }
  }

  Future<void> _test(
    RegressionRequest request,
    GlsPlan plan,
    StreamController<RegressionEvent> controller,
  ) async {
    final runId = request.runId;
    controller.add(TestStarted(runId: runId, testId: plan.gateId));
    void log(String line) => controller.add(
      TestLog(
        runId: runId,
        testId: plan.gateId,
        line: line,
        fromStderr: false,
      ),
    );

    if (!plan.runs) {
      controller.add(
        TestFinished(
          runId: runId,
          result: _notRun(plan, runId, plan.skip!, detail: plan.skipDetail),
        ),
      );
      return;
    }
    final timeout = plan.original.timeout != Duration.zero
        ? plan.original.timeout
        : request.defaultTimeout;

    // The RTL rerun, with the same generated dump, so the comparator has an
    // RTL port dump only SimCrux wrote.
    log('gate level: RTL rerun of ${plan.original.id}');
    final rtl = await _phase(request, plan.rtlSpec!, timeout, 'rtl');
    if (_cancelled.contains(runId)) {
      controller.add(
        TestFinished(
          runId: runId,
          result: _notRun(
            plan,
            runId,
            GlsNotRunReason.cancelled,
            status: TestStatus.cancelled,
          ),
        ),
      );
      return;
    }
    final rtlResult = rtl.result;
    if (rtlResult == null || !rtlResult.didExecute) {
      controller.add(
        TestFinished(
          runId: runId,
          result: _notRun(
            plan,
            runId,
            GlsNotRunReason.toolMissing,
            message: rtlResult?.failureMessage,
          ),
        ),
      );
      return;
    }
    if (!_passed(rtlResult)) {
      final built = !_compileFailed(rtlResult);
      final reason = built
          ? GlsNotRunReason.failsAtRtl
          : rtl.lines.any(kPortShapeMessage.hasMatch)
          ? GlsNotRunReason.portShape
          : GlsNotRunReason.rtlBuildFailed;
      for (final line in rtl.lines.take(20)) {
        controller.add(
          TestLog(
            runId: runId,
            testId: plan.gateId,
            line: line,
            fromStderr: true,
          ),
        );
      }
      controller.add(
        TestFinished(
          runId: runId,
          result: _notRun(
            plan,
            runId,
            reason,
            message: rtlResult.failureMessage,
          ),
        ),
      );
      return;
    }

    log('gate level: ${info.netlistKind} netlist, ${plan.original.id}');
    final gate = await _phase(request, plan.gateSpec!, timeout, 'gate');
    for (final line in gate.lines) {
      controller.add(
        TestLog(
          runId: runId,
          testId: plan.gateId,
          line: line,
          fromStderr: true,
        ),
      );
    }
    if (_cancelled.contains(runId)) {
      controller.add(
        TestFinished(
          runId: runId,
          result: _notRun(
            plan,
            runId,
            GlsNotRunReason.cancelled,
            status: TestStatus.cancelled,
          ),
        ),
      );
      return;
    }
    final gateResult = gate.result;
    if (gateResult == null || !gateResult.didExecute) {
      controller.add(
        TestFinished(
          runId: runId,
          result: _notRun(
            plan,
            runId,
            GlsNotRunReason.toolMissing,
            message: gateResult?.failureMessage,
          ),
        ),
      );
      return;
    }
    if (_compileFailed(gateResult)) {
      controller.add(
        TestFinished(
          runId: runId,
          result: _notRun(
            plan,
            runId,
            gate.lines.any(kPortShapeMessage.hasMatch)
                ? GlsNotRunReason.portShape
                : GlsNotRunReason.gateBuildFailed,
            message: gateResult.failureMessage,
            base: gateResult,
          ),
        ),
      );
      return;
    }
    final gatePassed = _passed(gateResult);

    GlsComparison? comparison;
    GlsNotRunReason? compareProblem;
    final rtlVcd = plan.rtlVcd!;
    final gateVcd = plan.gateVcd!;
    final scope = plan.scope!;
    final clock = plan.clock!;
    final names = plan.ports.toSet();
    final vcdLimits = limits;
    try {
      comparison = await background(
        () => GlsTraceComparator.compareFiles(
          rtlPath: rtlVcd,
          gatePath: gateVcd,
          scope: scope,
          ports: names,
          clock: clock,
          limits: vcdLimits,
        ),
      );
    } on GlsVcdException catch (e) {
      compareProblem = e.problem == GlsVcdProblem.tooLarge
          ? GlsNotRunReason.vcdTooLarge
          : GlsNotRunReason.vcdUnreadable;
    }

    final GlsOutcome outcome;
    GlsNotRunReason? reason;
    if (!gatePassed) {
      // The testbench fails at gate level: differs, with whatever counts the
      // dumps gave.
      outcome = GlsOutcome.differs;
    } else if (compareProblem != null) {
      outcome = GlsOutcome.notRun;
      reason = compareProblem;
    } else if (comparison == null || comparison.samplesCompared == 0) {
      outcome = GlsOutcome.notRun;
      reason = GlsNotRunReason.noSamples;
    } else if (comparison.realDiffs > 0) {
      outcome = GlsOutcome.differs;
    } else if (comparison.xDiffs > 0) {
      outcome = GlsOutcome.xOnly;
    } else {
      outcome = GlsOutcome.equal;
    }
    final result = _result(
      plan,
      runId,
      gateResult,
      outcome: outcome,
      reason: reason,
      comparison: comparison,
      gatePassed: gatePassed,
    );
    log(_summary(outcome, comparison, reason, gatePassed: gatePassed));
    controller.add(TestFinished(runId: runId, result: result));
  }

  String _summary(
    GlsOutcome outcome,
    GlsComparison? comparison,
    GlsNotRunReason? reason, {
    required bool gatePassed,
  }) {
    final parts = <String>['gate level: ${outcome.wireName}'];
    if (reason != null) parts.add('reason ${reason.wireName}');
    if (!gatePassed) parts.add('the testbench failed at gate level');
    if (comparison != null) {
      parts
        ..add('${comparison.realDiffs} real')
        ..add('${comparison.xDiffs} x-asymmetry');
    }
    return parts.join(', ');
  }

  static bool _passed(TestResult r) =>
      r.status == TestStatus.pass || r.status == TestStatus.vacuous;

  static bool _compileFailed(TestResult r) {
    final message = r.failureMessage ?? '';
    return message.startsWith('compile failed') ||
        message.startsWith('compile timed out');
  }

  Future<({TestResult? result, List<String> lines})> _phase(
    RegressionRequest request,
    TestSpec spec,
    Duration timeout,
    String label,
  ) async {
    final sub = '${request.runId}.$label.${spec.id.hashCode.toUnsigned(32)}';
    (_active[request.runId] ??= <String>{}).add(sub);
    TestResult? result;
    final lines = <String>[];
    try {
      await for (final event in inner.submit(
        RegressionRequest(
          runId: sub,
          tests: <TestSpec>[spec],
          defaultTimeout: timeout,
        ),
      )) {
        switch (event) {
          case TestFinished(result: final r):
            result = r;
          case TestLog(:final line):
            if (lines.length >= 400) lines.removeAt(0);
            lines.add(line);
          default:
            break;
        }
      }
    } finally {
      _active[request.runId]?.remove(sub);
    }
    return (result: result, lines: lines);
  }

  TestResult _notRun(
    GlsPlan plan,
    String runId,
    GlsNotRunReason reason, {
    String? detail,
    String? message,
    TestStatus status = TestStatus.fail,
    TestResult? base,
  }) {
    final now = DateTime.now().toUtc();
    final metrics = _metrics(
      plan,
      outcome: GlsOutcome.notRun,
      reason: reason,
      comparison: null,
    );
    final text = 'did not run: ${reason.wireName}';
    return (base ??
            TestResult(
              testId: plan.gateId,
              runId: runId,
              status: status,
              startedAt: now,
              finishedAt: now,
              didExecute: false,
              boundParameters: plan.original.parameters.isEmpty
                  ? null
                  : plan.original.parameters,
              parentSpecId: plan.original.parentSpecId,
              executionSeed: plan.original.seed,
            ))
        .copyWith(
          testId: plan.gateId,
          runId: runId,
          status: status,
          failureMessage: message == null || message.isEmpty
              ? (detail == null ? text : '$text ($detail)')
              : '$text: $message',
          metrics: metrics,
          didExecute: false,
        );
  }

  TestResult _result(
    GlsPlan plan,
    String runId,
    TestResult gate, {
    required GlsOutcome outcome,
    required GlsNotRunReason? reason,
    required GlsComparison? comparison,
    required bool gatePassed,
  }) {
    final strict = options.strictX;
    final passes = outcome.passes(strictX: strict);
    final String? message;
    if (outcome == GlsOutcome.notRun) {
      message = 'did not run: ${reason!.wireName}';
    } else if (!gatePassed) {
      message = gate.failureMessage ?? 'the testbench fails at gate level';
    } else if (outcome == GlsOutcome.differs) {
      message =
          'differs: ${comparison!.realDiffs} real, '
          '${comparison.xDiffs} x-asymmetry';
    } else if (outcome == GlsOutcome.xOnly && strict) {
      message = 'x-asymmetry only, and strict x is on';
    } else {
      message = null;
    }
    return gate.copyWith(
      testId: plan.gateId,
      runId: runId,
      status: passes ? TestStatus.pass : TestStatus.fail,
      failureMessage: message,
      waveformPath: File(plan.gateVcd!).existsSync() ? plan.gateVcd : null,
      metrics: _metrics(
        plan,
        outcome: outcome,
        reason: reason,
        comparison: comparison,
      ),
      didExecute: outcome != GlsOutcome.notRun,
    );
  }

  Map<String, String> _metrics(
    GlsPlan plan, {
    required GlsOutcome outcome,
    required GlsNotRunReason? reason,
    required GlsComparison? comparison,
  }) {
    final models = info.models;
    return <String, String>{
      GlsMetricKeys.outcome: outcome.wireName,
      if (reason != null) GlsMetricKeys.reason: reason.wireName,
      GlsMetricKeys.netlist: info.netlistKind,
      GlsMetricKeys.delays: 'functional',
      GlsMetricKeys.simulator:
          plan.gateSpec?.simulatorId ??
          glsSimulatorIdFor(plan.original.simulatorId) ??
          'icarus',
      if (comparison != null) ...<String, String>{
        GlsMetricKeys.realDiffs: '${comparison.realDiffs}',
        GlsMetricKeys.xDiffs: '${comparison.xDiffs}',
        if (comparison.firstDiffPs != null)
          GlsMetricKeys.firstDiffPs: '${comparison.firstDiffPs}',
      },
      GlsMetricKeys.flowRun: info.flowRunId,
      GlsMetricKeys.runDir: info.runRoot,
      GlsMetricKeys.target: info.target,
      if (info.pdk != null) GlsMetricKeys.pdk: info.pdk!,
      GlsMetricKeys.strictX: '${options.strictX}',
      GlsMetricKeys.bannered: '${models.bannered}',
      GlsMetricKeys.versionDiffers:
          '${models.warnings.contains(PdkModelsWarning.versionDiffers)}',
      GlsMetricKeys.rtlTest: plan.original.id,
      if (plan.clock != null) GlsMetricKeys.clock: plan.clock!,
      if (plan.scope != null) GlsMetricKeys.scope: plan.scope!,
      if (plan.rtlVcd != null && File(plan.rtlVcd!).existsSync())
        GlsMetricKeys.rtlVcd: plan.rtlVcd!,
      if (plan.gateVcd != null && File(plan.gateVcd!).existsSync())
        GlsMetricKeys.gateVcd: plan.gateVcd!,
    };
  }
}
