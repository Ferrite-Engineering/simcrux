// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_flow/crux_flow.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// How far one PDK's gate-level simulation has been measured.
enum PdkGlsStatus {
  /// Measured on a real LibreLane run: the testbench binds the netlist, the
  /// models resolve and Icarus reports no real difference.
  measured,

  /// The models resolve and the netlist binds, but gate-level simulation was
  /// not measured with a design Icarus can judge, so a result ships with a
  /// banner.
  bannered,
}

/// One row of the per-PDK gate-level table: what is known about simulating
/// this PDK's netlists, and under which provenance.
@immutable
class PdkGlsRow {
  /// Creates a row.
  const PdkGlsRow({
    required this.family,
    required this.prefixes,
    required this.status,
    required this.provenance,
  });

  /// The telemetry-style family name (`sky130`, `gf180mcu`, `ihp_sg13g2`).
  final String family;

  /// Lower-case prefixes a LibreLane `PDK` value starts with to belong to
  /// this row.
  final List<String> prefixes;

  /// Whether the row is measured or bannered.
  final PdkGlsStatus status;

  /// Where the status comes from: the gate document and what it measured.
  final String provenance;

  /// Whether a result on this PDK carries the "not measured" banner.
  bool get bannered => status == PdkGlsStatus.bannered;
}

/// The versioned per-PDK table behind [PdkCellModels]: one row per PDK
/// family, with the provenance of its status.
///
/// The cell models themselves are never listed here. They are exactly the
/// run's own `CELL_VERILOG_MODELS`, in the order the run records, so a new
/// library or PDK release needs no table edit; the table only says how far a
/// family's gate-level simulation has been measured.
abstract final class PdkGlsTable {
  /// The sky130 row: measured on LibreLane 3.0.16 runs of a small design and
  /// of PicoRV32, `sky130_fd_sc_hd`.
  static const PdkGlsRow sky130 = PdkGlsRow(
    family: 'sky130',
    prefixes: <String>['sky130'],
    status: PdkGlsStatus.measured,
    provenance:
        'LibreLane 3.0.16, sky130A, sky130_fd_sc_hd: Icarus reports 0 real '
        'differences on the adder and on PicoRV32 '
        '(verification/fixtures/flow/gate_level/GLS-GATE.md)',
  );

  /// The gf180mcuD row. Bannered: the models resolve and the netlist binds,
  /// Icarus ran only the small adder (which stays unknown for ever and so
  /// cannot be judged), and Verilator's gate runs failed.
  static const PdkGlsRow gf180mcu = PdkGlsRow(
    family: 'gf180mcu',
    prefixes: <String>['gf180mcu'],
    status: PdkGlsStatus.bannered,
    provenance:
        'LibreLane 3.0.16, gf180mcuD: models resolve and bind; Icarus ran '
        'only the adder, which never leaves x; Verilator gate runs fail '
        '(GLS-GATE.md)',
  );

  /// The ihp-sg13g2 row. Bannered for the same reasons as [gf180mcu].
  static const PdkGlsRow ihp = PdkGlsRow(
    family: 'ihp_sg13g2',
    prefixes: <String>['ihp-sg13g2', 'ihp_sg13g2'],
    status: PdkGlsStatus.bannered,
    provenance:
        'LibreLane 3.0.16, ihp-sg13g2: models resolve and bind; Icarus ran '
        'only the adder, which never leaves x; Verilator gate runs fail '
        '(GLS-GATE.md)',
  );

  /// A PDK no row names: simulated from its recorded models, unmeasured.
  static const PdkGlsRow other = PdkGlsRow(
    family: 'other',
    prefixes: <String>[],
    status: PdkGlsStatus.bannered,
    provenance: "not in the table: simulated from the run's recorded models",
  );

  /// Every row that names a PDK.
  static const List<PdkGlsRow> rows = <PdkGlsRow>[sky130, gf180mcu, ihp];

  /// The row for the LibreLane `PDK` value [pdk] (`sky130A`, `gf180mcuD`,
  /// `ihp-sg13g2`), or [other].
  static PdkGlsRow rowFor(String? pdk) {
    final lower = (pdk ?? '').toLowerCase();
    for (final row in rows) {
      if (row.prefixes.any(lower.startsWith)) return row;
    }
    return other;
  }
}

/// Why the cell models could not be resolved.
enum PdkModelsProblem {
  /// The run records no `CELL_VERILOG_MODELS`.
  notRecorded,

  /// A recorded model file exists nowhere SimCrux looked.
  notFound,

  /// A model resolves outside the PDK root and the run root.
  outside,
}

/// A note on a resolved model set that the row carries.
enum PdkModelsWarning {
  /// The PDK version the run recorded is not installed here; the models come
  /// from the PDK this machine has enabled, which may differ.
  versionDiffers,
}

/// The cell models of one run, or why there are none.
@immutable
class PdkCellModelResolution {
  /// Creates a resolution.
  const PdkCellModelResolution({
    required this.row,
    this.pdk,
    this.stdCellLibrary,
    this.models = const <String>[],
    this.pdkRoot,
    this.recordedVersion,
    this.warnings = const <PdkModelsWarning>[],
    this.problem,
    this.problemDetail,
    this.powerDefine = 'USE_POWER_PINS',
  });

  /// The table row for the run's PDK.
  final PdkGlsRow row;

  /// `PDK` from the run (`sky130A`).
  final String? pdk;

  /// `STD_CELL_LIBRARY` from the run.
  final String? stdCellLibrary;

  /// The model files to compile, in the order the run records them, resolved
  /// to the files that exist here. Empty when [problem] is set.
  final List<String> models;

  /// The PDK root the models came from.
  final String? pdkRoot;

  /// The PDK version the run recorded: the open_pdks commit that names the
  /// versioned directory in `PDK_ROOT`, when it names one.
  final String? recordedVersion;

  /// Notes the result row carries.
  final List<PdkModelsWarning> warnings;

  /// Why [models] is empty, when it is.
  final PdkModelsProblem? problem;

  /// The file the [problem] is about, as a base name: never a full path, so
  /// it can be shown beside a path a run's own files named.
  final String? problemDetail;

  /// The define that switches the power-aware netlist's supply ports on.
  final String powerDefine;

  /// Whether the models resolved.
  bool get ok => problem == null && models.isNotEmpty;

  /// Whether a result carries the "not measured" banner.
  bool get bannered => row.bannered;
}

/// Finds the PDK's Verilog cell models for a LibreLane run, from the run's
/// own `resolved.json` and never from a search of the disk.
///
/// The run records `PDK_ROOT` (ciel's versioned directory itself on the
/// measured runs: `~/.ciel/ciel/<family>/versions/<open_pdks commit>`),
/// `PDK`, `STD_CELL_LIBRARY` and `CELL_VERILOG_MODELS`, an ordered list that
/// is used as it is. A run copied from another machine records that
/// machine's paths; the models are then looked for at the same versioned
/// directory under this machine's PDK manager root, ciel and volare both.
/// A PDK version that differs from the run's is a warning on the row, never a
/// silent substitution. Nothing here downloads a file.
///
/// Every model path is resolved through its symbolic links and must lie
/// inside the PDK root or the run root. The PDK root is always one this
/// machine has (the fallback the caller passes, `PDK_ROOT` in the
/// environment, `~/.ciel`, `~/.volare`, or a directory inside one of them),
/// never a directory the run alone names.
abstract final class PdkCellModels {
  /// The `FUNCTIONAL` define the models need for a functional simulation.
  static const String functionalDefine = 'FUNCTIONAL';

  /// The unit delay every gate carries in a functional simulation, so a
  /// zero-delay race cannot reorder a clocked capture.
  static const String unitDelayDefine = 'UNIT_DELAY';

  /// The value of [unitDelayDefine].
  static const String unitDelayValue = '#1';

  /// The defines a functional gate-level simulation adds: `FUNCTIONAL`,
  /// `UNIT_DELAY=#1`, and for the power-aware netlist the run's power define.
  static Map<String, String> definesFor(
    PdkCellModelResolution resolution, {
    required bool powerAware,
  }) => <String, String>{
    functionalDefine: '1',
    unitDelayDefine: unitDelayValue,
    if (powerAware) resolution.powerDefine: '1',
  };

  /// The defines a delay-annotated gate-level simulation adds: neither
  /// `FUNCTIONAL` nor `UNIT_DELAY`, so the models' timing variants (the ones
  /// with `specify` paths for the annotation to fill) are compiled; for the
  /// power-aware netlist the run's power define.
  static Map<String, String> annotatedDefinesFor(
    PdkCellModelResolution resolution, {
    required bool powerAware,
  }) => <String, String>{
    if (powerAware) resolution.powerDefine: '1',
  };

  /// Resolves the models of the run whose `resolved.json` is [resolved] and
  /// whose root is [runRoot].
  ///
  /// [pdkRootFallback] is the probe's `PDK_ROOT` (a manager root such as
  /// `~/.ciel`, or a classic PDK root holding `<pdk>/`); [home] is the user's
  /// home, whose `.ciel` and `.volare` are looked in last.
  static PdkCellModelResolution resolve({
    required Map<String, Object?> resolved,
    required String runRoot,
    String? pdkRootFallback,
    String? home,
  }) {
    final pdk = _string(resolved['PDK']);
    final library = _string(resolved['STD_CELL_LIBRARY']);
    final row = PdkGlsTable.rowFor(pdk);
    final powerDefine =
        _string(resolved['VERILOG_POWER_DEFINE']) ?? 'USE_POWER_PINS';
    final recordedRoot = _string(resolved['PDK_ROOT']);
    final recorded = _versioned(recordedRoot);

    PdkCellModelResolution failed(
      PdkModelsProblem problem, [
      String? detail,
    ]) => PdkCellModelResolution(
      row: row,
      pdk: pdk,
      stdCellLibrary: library,
      recordedVersion: recorded?.version,
      problem: problem,
      problemDetail: detail,
      powerDefine: powerDefine,
    );

    final recordedModels = <String>[];
    final raw = resolved['CELL_VERILOG_MODELS'];
    if (raw is List<Object?>) {
      for (final item in raw) {
        final s = _string(item);
        if (s != null) recordedModels.add(s);
      }
    }
    if (recordedModels.isEmpty) return failed(PdkModelsProblem.notRecorded);

    // Candidate roots, best first: the recorded one, the same versioned
    // directory under each manager root, then the enabled PDK of each.
    final bases = <String>[
      ?pdkRootFallback,
      ?Platform.environment['PDK_ROOT'],
      if (home != null) ...<String>[
        p.join(home, '.ciel'),
        p.join(home, '.volare'),
      ],
    ];
    // The recorded `PDK_ROOT` is a hint from the run, not a permission: it
    // is a containment root only when it lies inside (or is) one of this
    // user's own PDK roots. A run that names `/`, or any directory of its
    // choosing, goes straight to the relocation candidates below, which
    // rebase its recorded paths onto those roots.
    final trustRecorded =
        recordedRoot != null &&
        bases.isNotEmpty &&
        FlowContainment(bases).allows(recordedRoot);
    // `root` is where a recorded model's path relative to the recorded
    // `PDK_ROOT` is joined; `contain` is the directory every model must lie
    // inside. The two differ for the enabled PDK (`<base>/<pdk>`), whose
    // relative paths already start with `<pdk>/`.
    final candidates = <({String root, String contain, bool sameVersion})>[
      if (trustRecorded)
        (root: recordedRoot, contain: recordedRoot, sameVersion: true),
      if (recorded != null)
        for (final base in bases)
          for (final manager in const <String>['ciel', 'volare'])
            (
              root: p.join(
                base,
                manager,
                recorded.family,
                'versions',
                recorded.version,
              ),
              contain: p.join(
                base,
                manager,
                recorded.family,
                'versions',
                recorded.version,
              ),
              sameVersion: true,
            ),
      if (pdk != null)
        for (final base in bases)
          (root: base, contain: p.join(base, pdk), sameVersion: false),
    ];

    for (final candidate in candidates) {
      final models = <String>[];
      for (final model in recordedModels) {
        final found = _locate(model, recordedRoot, candidate.root);
        if (found == null) break;
        models.add(found);
      }
      if (models.length != recordedModels.length) continue;
      final containment = FlowContainment(<String>[candidate.contain, runRoot]);
      final inside = <String>[];
      for (final model in models) {
        final refusal = containment.refuse(model);
        if (refusal != null) {
          return failed(PdkModelsProblem.outside, p.basename(model));
        }
        inside.add(containment.require(model));
      }
      return PdkCellModelResolution(
        row: row,
        pdk: pdk,
        stdCellLibrary: library,
        models: inside,
        pdkRoot: candidate.contain,
        recordedVersion: recorded?.version,
        warnings: candidate.sameVersion
            ? const <PdkModelsWarning>[]
            : const <PdkModelsWarning>[PdkModelsWarning.versionDiffers],
        powerDefine: powerDefine,
      );
    }
    return failed(PdkModelsProblem.notFound, p.basename(recordedModels.first));
  }

  /// [model] as the file under [candidateRoot] that exists, or null. A model
  /// that exists where the run recorded it is used there.
  static String? _locate(
    String model,
    String? recordedRoot,
    String candidateRoot,
  ) {
    if (recordedRoot != null &&
        candidateRoot == recordedRoot &&
        File(model).existsSync()) {
      return model;
    }
    if (recordedRoot != null && p.isWithin(recordedRoot, model)) {
      final moved = p.join(
        candidateRoot,
        p.relative(model, from: recordedRoot),
      );
      if (File(moved).existsSync()) return moved;
      return null;
    }
    // A model outside the recorded PDK root (or a run that records none) is
    // used where it is, and only the root check below can accept it.
    return File(model).existsSync() ? model : null;
  }

  static String? _string(Object? value) =>
      value is String && value.trim().isNotEmpty ? value : null;

  /// The family and version a ciel or volare versioned directory names
  /// (`.../<manager>/<family>/versions/<hash>`), or null.
  static ({String family, String version})? _versioned(String? root) {
    if (root == null) return null;
    final parts = p.split(p.normalize(root));
    final at = parts.lastIndexOf('versions');
    if (at < 2 || at + 1 >= parts.length) return null;
    return (family: parts[at - 1], version: parts[at + 1]);
  }
}
