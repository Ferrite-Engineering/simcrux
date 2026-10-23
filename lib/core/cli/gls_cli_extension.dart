// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:args/args.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/services/flow/gate_level/gls_result.dart';
import 'package:simcrux/services/flow/gate_level/gls_run_info.dart';
import 'package:simcrux/services/flow/gate_level/gls_runner.dart';

/// What an edition adds to `flow gls`: its own options, a licence check, the
/// options its run uses, a scheduler between the pairs and the simulators,
/// and its own report.
///
/// `FlowCli` keeps everything the two simulations share (the line, the
/// project, the entry, the test selection, the run's netlist and models, the
/// planning, the run and the signal handling), so an edition never copies
/// them. This binary installs none: its `flow gls` is the functional
/// simulation.
///
/// **Nothing here may import Flutter**: the headless binaries link it.
abstract interface class GlsCliExtension {
  /// Adds the edition's options to the `flow gls` parser.
  void addOptions(ArgParser parser);

  /// Whether [results] asks for the edition's simulation. When false the line
  /// runs the functional simulation and nothing below is called.
  bool appliesTo(ArgResults results);

  /// Called once the line is valid and before any project, run or engine
  /// work: the licence check. A non-null code ends the command with it.
  Future<int?> admit(ArgResults results);

  /// The options the run uses, from the functional [options] and the run's
  /// [info]; or the code that ends the command. Called before anything runs.
  Future<GlsCliPrepared> prepare(
    ArgResults results,
    GlsRunInfo info,
    GlsOptions options,
  );

  /// The scheduler the RTL and gate runs go through: [inner], or one that
  /// wraps it.
  JobScheduler wrapInner(JobScheduler inner);

  /// Writes the finished run's report (stdout, stderr and the files the line
  /// names) and returns the exit code. [interrupted] is the signal's code
  /// when the run was interrupted.
  Future<int> report({
    required ArgResults results,
    required GlsRunInfo info,
    required List<TestResult> finished,
    required List<GlsResultView> views,
    int? interrupted,
  });
}

/// What [GlsCliExtension.prepare] decided: the options to run with, or the
/// exit code that ends the command.
class GlsCliPrepared {
  /// The run goes ahead with [options].
  const GlsCliPrepared.run(GlsOptions this.options) : code = null;

  /// The command ends with [code].
  const GlsCliPrepared.stop(int this.code) : options = null;

  /// The options to run with.
  final GlsOptions? options;

  /// The code the command ends with.
  final int? code;
}
