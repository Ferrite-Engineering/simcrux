// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

/// One program the formal flow may need.
enum FormalTool {
  /// SymbiYosys, the driver SimCrux spawns.
  sby('sby', essential: true),

  /// The equivalence front end.
  eqy('eqy'),

  /// Yosys, which `sby` runs to read the design.
  yosys('yosys', essential: true),

  /// The yosys-slang plugin, the SystemVerilog front end. Not a program: the
  /// probe asks Yosys to load it.
  yosysSlang('yosys-slang'),

  /// The SMT solver `smtbmc` uses by default.
  yicesSmt2('yices-smt2'),

  /// An SMT solver for `smtbmc boolector`.
  boolector('boolector'),

  /// An SMT solver for `smtbmc bitwuzla`.
  bitwuzla('bitwuzla'),

  /// An SMT solver for `smtbmc z3`.
  z3('z3'),

  /// ABC, for the `abc` engines (`abc pdr`, `abc bmc3`).
  yosysAbc('yosys-abc'),

  /// rIC3, an IC3 model checker.
  ric3('rIC3');

  const FormalTool(this.binaryName, {this.essential = false});

  /// The executable's conventional name.
  final String binaryName;

  /// Whether no formal run can work without it. The rest are needed only by
  /// the engines or front ends that name them.
  final bool essential;
}

/// What the probe found for one [FormalTool].
@immutable
class FormalToolReport {
  /// Creates a report row.
  const FormalToolReport({
    required this.tool,
    required this.binary,
    required this.found,
    this.version,
    this.verific,
  });

  /// The tool.
  final FormalTool tool;

  /// The executable probed: an absolute path or a name looked up on PATH.
  final String binary;

  /// Whether it answered.
  final bool found;

  /// Its first banner line, when it printed one.
  final String? version;

  /// For [FormalTool.yosys] only: whether this Yosys was built with Verific
  /// (the commercial SystemVerilog front end). Null for every other tool,
  /// and when Yosys itself was not found.
  final bool? verific;
}

/// The formal toolchain as the probe found it.
@immutable
class FormalToolchainReport {
  /// Creates a report.
  const FormalToolchainReport({required this.tools});

  /// One row per [FormalTool], in enum order.
  final List<FormalToolReport> tools;

  /// The row for [tool].
  FormalToolReport? operator [](FormalTool tool) {
    for (final row in tools) {
      if (row.tool == tool) return row;
    }
    return null;
  }

  /// Whether every [FormalTool.essential] tool answered.
  bool get ready => tools.where((t) => t.tool.essential).every((t) => t.found);

  /// The tools that did not answer.
  List<FormalTool> get missing => <FormalTool>[
    for (final row in tools)
      if (!row.found) row.tool,
  ];
}
