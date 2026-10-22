// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_flow/crux_flow.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/services/flow/flow_run_reading.dart';
import 'package:simcrux/services/flow/gate_level/gls_outcome.dart';
import 'package:simcrux/services/flow/gate_level/pdk_cell_models.dart';

/// What a gate-level simulation needs to know about the LibreLane run it
/// simulates: the netlist, the design sources the run synthesised, the cell
/// models and the clock, all from the run's own record.
@immutable
class GlsRunInfo {
  /// Creates the info.
  const GlsRunInfo({
    required this.runRoot,
    required this.design,
    required this.netlistKind,
    required this.netlistPath,
    required this.designSources,
    required this.models,
    required this.target,
    required this.flowRunId,
    this.clockPort,
    this.supplyPins = const <String>['VPWR', 'VGND'],
    this.pdk,
  });

  /// The run directory.
  final String runRoot;

  /// `DESIGN_NAME`: the netlist's top module.
  final String design;

  /// `nl` or `pnl`.
  final String netlistKind;

  /// The netlist, resolved inside [runRoot].
  final String netlistPath;

  /// `VERILOG_FILES`: the sources the run synthesised, as it records them.
  final List<String> designSources;

  /// The cell models, or why there are none.
  final PdkCellModelResolution models;

  /// The closed telemetry target token (`sky130`, `gf180mcu`, ...).
  final String target;

  /// The id the run is recorded under (the tag when the caller knows no
  /// other).
  final String flowRunId;

  /// `CLOCK_PORT`, when the run names one port.
  final String? clockPort;

  /// The power and ground pins a power-aware netlist ties (`VDD_PIN`,
  /// `GND_PIN`).
  final List<String> supplyPins;

  /// `PDK`.
  final String? pdk;

  /// Whether this is the power-aware netlist.
  bool get powerAware => netlistKind == 'pnl';

  /// Reads the run at [runRoot] for a simulation of its [netlist] (`nl` or
  /// `pnl`).
  ///
  /// [pdkRootFallback] and [home] are where models are looked for when the
  /// run came from another machine; [flowRunId] is the id the run is stored
  /// under. Returns the reason the run cannot be simulated when it cannot.
  /// Nothing is written.
  static Future<GlsRunInfoResult> read({
    required String runRoot,
    String netlist = 'nl',
    String? pdkRootFallback,
    String? home,
    String? flowRunId,
  }) async {
    final root = p.normalize(p.absolute(runRoot));
    if (!Directory(root).existsSync()) {
      return const GlsRunInfoResult(problem: GlsNotRunReason.runUnreadable);
    }
    final Map<String, Object?>? resolved;
    try {
      resolved = await readLibreLaneResolved(root, FlowInputLimits.defaults);
    } on FlowContainmentException {
      return const GlsRunInfoResult(problem: GlsNotRunReason.runUnreadable);
    } on FlowReadException {
      return const GlsRunInfoResult(problem: GlsNotRunReason.runUnreadable);
    }
    if (resolved == null) {
      return const GlsRunInfoResult(problem: GlsNotRunReason.runUnreadable);
    }
    final design = resolved['DESIGN_NAME'];
    if (design is! String || design.isEmpty) {
      return const GlsRunInfoResult(problem: GlsNotRunReason.runUnreadable);
    }
    final kind = netlist == 'pnl' ? 'pnl' : 'nl';
    final String path;
    try {
      path = FlowContainment(<String>[
        root,
      ]).require(p.join(root, 'final', kind, '$design.$kind.v'));
    } on FlowContainmentException {
      return const GlsRunInfoResult(problem: GlsNotRunReason.netlistMissing);
    }
    if (!File(path).existsSync()) {
      return const GlsRunInfoResult(problem: GlsNotRunReason.netlistMissing);
    }
    final models = PdkCellModels.resolve(
      resolved: resolved,
      runRoot: root,
      pdkRootFallback: pdkRootFallback,
      home: home,
    );
    final sources = <String>[];
    final raw = resolved['VERILOG_FILES'];
    if (raw is List<Object?>) {
      for (final item in raw) {
        if (item is String && item.isNotEmpty) sources.add(item);
      }
    }
    final clock = resolved['CLOCK_PORT'];
    String? pin(String key, String fallback) {
      final v = resolved![key];
      return v is String && v.isNotEmpty ? v : fallback;
    }

    final pdk = resolved['PDK'];
    return GlsRunInfoResult(
      info: GlsRunInfo(
        runRoot: root,
        design: design,
        netlistKind: kind,
        netlistPath: path,
        designSources: sources,
        models: models,
        target: librelaneTargetToken(pdk is String ? pdk : ''),
        flowRunId: flowRunId ?? p.basename(root),
        clockPort: clock is String && clock.isNotEmpty ? clock : null,
        supplyPins: <String>[pin('VDD_PIN', 'VPWR')!, pin('GND_PIN', 'VGND')!],
        pdk: pdk is String ? pdk : null,
      ),
    );
  }
}

/// A [GlsRunInfo], or why the run cannot be simulated.
@immutable
class GlsRunInfoResult {
  /// Creates a result.
  const GlsRunInfoResult({this.info, this.problem});

  /// The run, when it can be simulated.
  final GlsRunInfo? info;

  /// Why it cannot.
  final GlsNotRunReason? problem;
}
