// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/domain/models/riscv_config.dart';

/// How a formal test runs: against the real tool, or by replaying a
/// committed capture through the identical parsing path.
enum FormalRunMode {
  /// Spawn the tool. The default.
  normal('normal'),

  /// Spawn nothing; replay a captured log (and, when the case has one, its
  /// `status.sqlite`) through the same readers the real run feeds.
  demo('demo');

  const FormalRunMode(this.wireName);

  /// Stable token used in `simcrux.yaml`. Never localize it.
  final String wireName;

  /// Every accepted token, for error messages.
  static List<String> get wireNames =>
      FormalRunMode.values.map((m) => m.wireName).toList(growable: false);

  /// Parses a token, or null when it is not one of [wireNames].
  static FormalRunMode? fromWireName(Object? raw) {
    if (raw is! String) return null;
    for (final mode in FormalRunMode.values) {
      if (mode.wireName == raw) return mode;
    }
    return null;
  }
}

/// The general `formal:` block: one SymbiYosys task, or one EQY
/// equivalence check, per SimCrux test.
///
/// Separate from `riscv.formal:`, and both may appear on one test: the
/// RISC-V block is read only by the `riscv_formal` driver, this one by the
/// `sby` driver ([sbyFile], [task]) and the `eqy` driver ([eqyFile]).
/// Inherited at the same four levels as `riscv:`
/// (an including file's `defaults.formal`, the project's `defaults.formal`,
/// the suite's `formal:`, the test's `formal:`), merged field by field.
///
/// **Never tier-gated.** A formal verdict is correctness and is free.
///
/// The keys that choose what SimCrux executes are read through the
/// project-tooling gate: [command] and [extraArgs] refuse the load while
/// the gate is closed, [sbyBinary], [eqyBinary] and every [tools] entry are
/// dropped with an advisory and the conventional names on PATH are used
/// instead.
@immutable
class FormalConfig {
  /// Creates a [FormalConfig].
  const FormalConfig({
    this.sbyFile,
    this.task,
    this.sbyBinary,
    this.eqyFile,
    this.eqyBinary,
    this.ghdlBinary,
    this.command,
    this.extraArgs,
    this.tools,
    this.mode,
    this.demoOutputs,
    this.demoCase,
    this.projectRoot,
  });

  /// The `simulator:` id of the general SymbiYosys driver.
  static const String kSbySimulatorId = 'sby';

  /// The `simulator:` id of the EQY equivalence driver.
  static const String kEqySimulatorId = 'eqy';

  /// Conventional `sby` executable name, used when [sbyBinary] is unset.
  static const String kDefaultSbyBinary = 'sby';

  /// Conventional `eqy` executable name, used when [eqyBinary] is unset.
  static const String kDefaultEqyBinary = 'eqy';

  /// The [kToolKeys] `eqy` also accepts as `--<tool> <path>`. The others
  /// are SymbiYosys-only and are not passed to `eqy`.
  static const List<String> kEqyToolKeys = <String>[
    'yosys',
    'abc',
    'smtbmc',
    'suprove',
    'aigbmc',
    'avy',
    'btormc',
    'pono',
  ];

  /// The `sby` options that name a tool executable, as `formal.tools` keys.
  /// Each becomes `--<key> <path>` on the command line.
  static const List<String> kToolKeys = <String>[
    'yosys',
    'abc',
    'smtbmc',
    'witness',
    'suprove',
    'aigbmc',
    'avy',
    'rIC3',
    'btormc',
    'itp-bmc',
    'pono',
  ];

  /// The `.sby` job file, relative to the project file's directory or
  /// absolute. `sby` runs in its directory, so `[files]` entries resolve
  /// the way `sby` resolves them by hand.
  final String? sbyFile;

  /// The `[tasks]` name to run. Also names the task directory, so it must
  /// be a single safe path segment. When unset, the job file's basename
  /// names the directory and `sby` runs its default tasks, which must then
  /// be exactly one.
  final String? task;

  /// The SymbiYosys executable. Gated: dropped unless project tooling is
  /// allowed.
  final String? sbyBinary;

  /// The `.eqy` file, relative to the project file's directory or absolute.
  /// `eqy` runs in its directory, so the `[gold]` and `[gate]` scripts read
  /// their sources the way `eqy` reads them by hand. Its basename names the
  /// work directory, so it must be a single safe path segment.
  final String? eqyFile;

  /// The EQY executable. Gated like [sbyBinary].
  final String? eqyBinary;

  /// The standalone GHDL that lowers a VHDL `[gold]` or `[gate]` read to
  /// Verilog (`ghdl --synth --out=verilog`) before `eqy` runs. Gated like
  /// [sbyBinary]; when unset, the `ghdl` beside an absolute `eqy`, else on
  /// PATH.
  final String? ghdlBinary;

  /// Full argv override. Gated: refuses the load unless project tooling is
  /// allowed. Placeholders as [expandRiscvPlaceholders]: `{sby_file}`,
  /// `{eqy_file}`, `{task}`, `{task_dir}`, `{work_dir}`, `{name}`.
  final List<String>? command;

  /// Extra `sby` options inserted before the job file. Gated like
  /// [command].
  final List<String>? extraArgs;

  /// Tool executable overrides, `formal.tools.<tool>: <path>`, passed as
  /// `sby --<tool> <path>`. Gated like [sbyBinary]. Keys are [kToolKeys].
  final Map<String, String>? tools;

  /// Normal or demo. Null means normal.
  final FormalRunMode? mode;

  /// Root of a committed capture corpus for [FormalRunMode.demo]. Each
  /// immediate subdirectory is one case.
  final String? demoOutputs;

  /// The case under [demoOutputs] this test replays; defaults to the test
  /// name.
  final String? demoCase;

  /// The project file's directory, set by the loader (never read from
  /// YAML). Property locations are reported relative to it.
  final String? projectRoot;

  /// The run mode, defaulting to normal.
  FormalRunMode get effectiveMode => mode ?? FormalRunMode.normal;

  /// What is missing for a run, in plain English; empty when runnable.
  List<String> validateForRun() {
    if (effectiveMode == FormalRunMode.demo) {
      return <String>[
        if (demoOutputs == null || demoOutputs!.isEmpty)
          '`formal.demo_outputs` is required in demo mode.',
      ];
    }
    final hasCommand = command != null && command!.isNotEmpty;
    return <String>[
      if (!hasCommand && (sbyFile == null || sbyFile!.isEmpty))
        '`formal.sby_file` is required to run the sby driver.',
    ];
  }

  /// What is missing for an `eqy` run, in plain English; empty when
  /// runnable. There is no captured corpus to replay for EQY, so demo mode
  /// is refused rather than reported as a run.
  List<String> validateForEqyRun() {
    if (effectiveMode == FormalRunMode.demo) {
      const message =
          '`formal.mode: demo` replays SymbiYosys captures and is not '
          'available for the eqy driver.';
      return const <String>[message];
    }
    final hasCommand = command != null && command!.isNotEmpty;
    return <String>[
      if (!hasCommand && (eqyFile == null || eqyFile!.isEmpty))
        '`formal.eqy_file` is required to run the eqy driver.',
    ];
  }

  /// Returns a copy with the given fields replaced.
  FormalConfig copyWith({
    String? sbyFile,
    String? task,
    String? sbyBinary,
    String? eqyFile,
    String? eqyBinary,
    String? ghdlBinary,
    List<String>? command,
    List<String>? extraArgs,
    Map<String, String>? tools,
    FormalRunMode? mode,
    String? demoOutputs,
    String? demoCase,
    String? projectRoot,
  }) {
    return FormalConfig(
      sbyFile: sbyFile ?? this.sbyFile,
      task: task ?? this.task,
      sbyBinary: sbyBinary ?? this.sbyBinary,
      eqyFile: eqyFile ?? this.eqyFile,
      eqyBinary: eqyBinary ?? this.eqyBinary,
      ghdlBinary: ghdlBinary ?? this.ghdlBinary,
      command: command ?? this.command,
      extraArgs: extraArgs ?? this.extraArgs,
      tools: tools ?? this.tools,
      mode: mode ?? this.mode,
      demoOutputs: demoOutputs ?? this.demoOutputs,
      demoCase: demoCase ?? this.demoCase,
      projectRoot: projectRoot ?? this.projectRoot,
    );
  }

  /// Merges this block over [parent], field by field.
  FormalConfig mergeOnto(FormalConfig? parent) {
    if (parent == null) return this;
    return FormalConfig(
      sbyFile: sbyFile ?? parent.sbyFile,
      task: task ?? parent.task,
      sbyBinary: sbyBinary ?? parent.sbyBinary,
      eqyFile: eqyFile ?? parent.eqyFile,
      eqyBinary: eqyBinary ?? parent.eqyBinary,
      ghdlBinary: ghdlBinary ?? parent.ghdlBinary,
      command: command ?? parent.command,
      extraArgs: extraArgs ?? parent.extraArgs,
      tools: tools ?? parent.tools,
      mode: mode ?? parent.mode,
      demoOutputs: demoOutputs ?? parent.demoOutputs,
      demoCase: demoCase ?? parent.demoCase,
      projectRoot: projectRoot ?? parent.projectRoot,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FormalConfig &&
      other.sbyFile == sbyFile &&
      other.task == task &&
      other.sbyBinary == sbyBinary &&
      other.eqyFile == eqyFile &&
      other.eqyBinary == eqyBinary &&
      other.ghdlBinary == ghdlBinary &&
      riscvListEquals(other.command, command) &&
      riscvListEquals(other.extraArgs, extraArgs) &&
      _mapEquals(other.tools, tools) &&
      other.mode == mode &&
      other.demoOutputs == demoOutputs &&
      other.demoCase == demoCase &&
      other.projectRoot == projectRoot;

  @override
  int get hashCode => Object.hash(
    sbyFile,
    task,
    sbyBinary,
    eqyFile,
    eqyBinary,
    ghdlBinary,
    command == null ? null : Object.hashAll(command!),
    extraArgs == null ? null : Object.hashAll(extraArgs!),
    tools == null
        ? null
        : Object.hashAllUnordered(
            tools!.entries.map((e) => Object.hash(e.key, e.value)),
          ),
    mode,
    demoOutputs,
    demoCase,
    projectRoot,
  );

  static bool _mapEquals(Map<String, String>? a, Map<String, String>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }
}
