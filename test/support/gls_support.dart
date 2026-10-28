// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/resource_lock.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';

/// Where the gate-level fixtures are, from the repository root.
const String kGlFixtures = 'verification/fixtures/flow/gate_level';

/// The open_pdks commit the sky130 fixtures were measured on, which names the
/// versioned PDK directory the fake models are laid out under.
const String kGlPdkVersion = '8afc8346a57fe1ab7934ba5a6056ea8b43078e71';

/// What a [FakeGlsInner] answers for one spec.
typedef GlsAnswer = ({
  TestStatus status,
  String? failure,
  List<String> logs,
  bool executed,
});

/// A passing answer.
GlsAnswer glsPass() => (
  status: TestStatus.pass,
  failure: null,
  logs: const <String>[],
  executed: true,
);

/// A scheduler that answers from a script, for the gate-level planner, the
/// wrapper and the CLI without a simulator. Each submitted spec is answered by
/// [answer]; [onRun] sees the spec first, to write the port dumps a real
/// simulator would have written.
class FakeGlsInner implements JobScheduler {
  /// Creates the scheduler.
  FakeGlsInner(this.answer, {this.onRun});

  /// The answer for a spec.
  final GlsAnswer Function(TestSpec spec) answer;

  /// Called with each spec before it is answered.
  final void Function(TestSpec spec)? onRun;

  /// Every spec submitted, in order.
  final List<TestSpec> submitted = <TestSpec>[];

  /// Every run id cancelled.
  final List<String> cancelled = <String>[];

  @override
  Map<String, ResourceLock> get heldLocks => const <String, ResourceLock>{};

  @override
  RegressionStatus statusOf(String runId) => RegressionStatus(
    runId: runId,
    totalTests: 0,
    completedTests: 0,
    runningTests: 0,
    isFinished: true,
  );

  @override
  Future<void> cancel(String runId) async => cancelled.add(runId);

  @override
  Stream<RegressionEvent> submit(RegressionRequest request) async* {
    for (final spec in request.tests) {
      submitted.add(spec);
      onRun?.call(spec);
      final a = answer(spec);
      for (final line in a.logs) {
        yield TestLog(
          runId: request.runId,
          testId: spec.id,
          line: line,
          fromStderr: true,
        );
      }
      final now = DateTime.now().toUtc();
      yield TestFinished(
        runId: request.runId,
        result: TestResult(
          testId: spec.id,
          runId: request.runId,
          status: a.status,
          startedAt: now,
          finishedAt: now,
          failureMessage: a.failure,
          didExecute: a.executed,
          executionSeed: spec.seed,
          boundParameters: spec.parameters.isEmpty ? null : spec.parameters,
        ),
      );
    }
    yield RegressionFinished(runId: request.runId, cancelled: false);
  }
}

/// An `onRun` for [FakeGlsInner] that writes the port dump a real Icarus
/// would have written: for a spec that elaborates the generated `gls_portdump`
/// top, the MAC fixture VCD [rtl] (for an RTL rerun) or [gate] (for the gate
/// run) is copied to the path the generated module dumps to.
void Function(TestSpec spec) glsVcdWriter({
  required String rtl,
  required String gate,
}) => (spec) {
  if (!spec.extraTops.contains('gls_portdump')) return;
  final dump = spec.sources.firstWhere(
    (s) => p.basename(s) == 'gls_portdump.v',
  );
  final target = RegExp(
    r'\$dumpfile\("([^"]+)"\)',
  ).firstMatch(File(dump).readAsStringSync())!.group(1)!;
  final fixture = spec.id.startsWith('gls-rtl/') ? rtl : gate;
  File('$kGlFixtures/mac/vcd/$fixture.vcd').copySync(target);
};

/// Lays out a LibreLane run directory for the research MAC at [run]:
/// `resolved.json` naming the design source and fake cell models under
/// [pdkParent], and `final/<kind>/` holding the fixture [netlist] as
/// `dut.<kind>.v`. Returns the PDK root the record names.
String writeMacRun({
  required String run,
  required String pdkParent,
  String netlist = 'net.v',
  String kind = 'nl',
  Map<String, Object?> extra = const <String, Object?>{},
  bool withModels = true,
}) {
  // Under `<pdkParent>/.ciel`, ciel's own layout: a run's recorded PDK root
  // is trusted only inside one of the user's PDK roots, so callers pass
  // [pdkParent] as the home (or `<pdkParent>/.ciel` as the PDK root).
  final root = p.join(
    pdkParent,
    '.ciel',
    'ciel',
    'sky130',
    'versions',
    kGlPdkVersion,
  );
  final verilog = p.join(
    root,
    'sky130A',
    'libs.ref',
    'sky130_fd_sc_hd',
    'verilog',
  );
  Directory(verilog).createSync(recursive: true);
  File(p.join(verilog, 'primitives.v')).writeAsStringSync('// udp\n');
  File(p.join(verilog, 'sky130_fd_sc_hd.v')).writeAsStringSync('// cells\n');
  Directory(p.join(run, 'final', kind)).createSync(recursive: true);
  File(
    '$kGlFixtures/mac/$netlist',
  ).copySync(p.join(run, 'final', kind, 'dut.$kind.v'));
  File(p.join(run, 'resolved.json')).writeAsStringSync(
    jsonEncode(<String, Object?>{
      'PDK': 'sky130A',
      'STD_CELL_LIBRARY': 'sky130_fd_sc_hd',
      'DESIGN_NAME': 'dut',
      'CLOCK_PORT': 'clk',
      'PDK_ROOT': root,
      'VERILOG_POWER_DEFINE': 'USE_POWER_PINS',
      'VDD_PIN': 'VPWR',
      'GND_PIN': 'VGND',
      'VERILOG_FILES': <String>[p.absolute('$kGlFixtures/mac/dut.v')],
      if (withModels)
        'CELL_VERILOG_MODELS': <String>[
          p.join(verilog, 'primitives.v'),
          p.join(verilog, 'sky130_fd_sc_hd.v'),
        ],
      ...extra,
    }),
  );
  return root;
}
