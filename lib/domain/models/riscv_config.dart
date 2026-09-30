// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/golden_compare_profile.dart';
import 'package:simcrux/domain/enums/riscv_reference_model.dart';
import 'package:simcrux/domain/enums/riscv_run_mode.dart';

/// The `riscv:` block, after four-level inheritance has been flattened.
///
/// Schema: https://docs.simcrux.app/projects-and-simulators#riscv.
/// Every field is
/// nullable so [mergeOnto] can distinguish "this level said nothing" from
/// "this level said the default", which is what makes
/// **include file → project `defaults:` → suite → test** work as four
/// levels rather than three.
///
/// ## Tiering
///
/// **Nothing on this path is tier-gated — deliberately, and forever**: a
/// compatibility verdict is correctness, and monetizing it would read as
/// tolling RVI's own standard.
/// The config loader already carries a tier gate, `_parameterizationUnlocked`,
/// which gates `seeds:` / `parameters:` sweep expansion; the `riscv:` reader
/// has no analogue and must never acquire one, including after `kBetaPeriod`
/// flips to `false`. The asymmetry is the point: sweeps are a *productivity*
/// feature and are Pro, while a compatibility verdict is *correctness* and is
/// free. Compatibility is RVI's own program, and monetizing the verdict would
/// be read as tolling a standard. A later consistency pass must not "fix"
/// this. The same reasoning, at the detector's own reader, is recorded in
/// `config_loader_pass_fail.dart` next to `_readGoldenCompareConfig`.
@immutable
class RiscvConfig {
  /// Creates a [RiscvConfig]. Every field is optional; an all-null
  /// instance is the "nothing declared at this level" value.
  const RiscvConfig({
    this.isa,
    this.reference,
    this.archTest,
    this.toolchain,
    this.target,
    this.compile,
    this.riscof,
    this.signature,
    this.formal,
    this.extensions,
    this.mode,
    this.demoSignatures,
    this.testPath,
    this.extension,
    this.demoCase,
  });

  /// `TestSpec.simulatorId` the architectural-compatibility driver claims.
  ///
  /// Lives in `domain/` rather than on the driver so the config loader can
  /// scope its completeness checks to `riscv_arch` tests without importing
  /// a service.
  static const String kSimulatorId = 'riscv_arch';

  /// `TestSpec.simulatorId` the riscv-formal driver claims.
  ///
  /// A second id rather than a `riscv_arch` mode, because the two share
  /// **nothing** at run time: one cross-compiles an architectural test and
  /// compares signature dumps, the other runs a bounded proof and reads a
  /// SymbiYosys log. They share the `riscv:` block, which is why both live
  /// in this file, and the loader scopes each driver's completeness checks
  /// by id.
  static const String kFormalSimulatorId = 'riscv_formal';

  /// Default signature granularity in bytes when `signature.word_size` is
  /// not declared. Four bytes is the arch-test convention for both RV32
  /// and RV64 signature dumps.
  static const int kDefaultWordSize = 4;

  /// Target ISA string, e.g. `rv32imc_zicsr_zifencei`.
  ///
  /// **Descriptive of what the DUT claims; never used to infer a verdict.**
  /// The Pro dashboard's ISA attestation derives from what
  /// actually *passed*, not from this string.
  final String? isa;

  /// The golden reference model and how to invoke it.
  final RiscvReferenceConfig? reference;

  /// Where the `riscv-arch-test` suite lives, and at what revision.
  final RiscvArchTestConfig? archTest;

  /// The RISC-V GNU cross-compiler's prefix and directory.
  final RiscvToolchainConfig? toolchain;

  /// How to run the DUT for one architectural test.
  final RiscvTargetConfig? target;

  /// How to cross-compile one architectural test into an ELF.
  final RiscvCompileConfig? compile;

  /// The user's own RISCOF invocation, for `mode: riscof_passthrough`.
  final RiscvRiscofConfig? riscof;

  /// Where the two signatures land and how wide a signature word is.
  final RiscvSignatureConfig? signature;

  /// `riscv.formal:` — the riscv-formal / SymbiYosys check set.
  ///
  /// Inert under the `riscv_arch` driver and vice versa: a project that
  /// runs both flows declares the shared plumbing (`isa`, `mode`) once and
  /// each driver reads only the sub-block it owns.
  final RiscvFormalConfig? formal;

  /// Extensions to import / report on, e.g. `[I, M, C, Zicsr]`. Consumed by
  /// [RiscvArchTestImporter] when enumerating and echoed onto results.
  final List<String>? extensions;

  /// Which of the three flows this test runs. See [RiscvRunMode].
  final RiscvRunMode? mode;

  /// Root of the committed pre-captured signature corpus used by
  /// [RiscvRunMode.demo]. Each immediate subdirectory is one case.
  final String? demoSignatures;

  /// **Per-test.** The architectural test's source, relative to
  /// [RiscvArchTestConfig.suitePath] (or absolute). Written by the
  /// importer; a hand-written config may set it directly.
  final String? testPath;

  /// **Per-test.** The extension this test exercises (`I`, `M`, `C`,
  /// `Zicsr`, …). This is how "maps each test to its extension" is carried
  /// — it rides into `TestResult.metrics` as `riscv.extension`, which is
  /// what the Pro per-extension rollup groups on.
  final String? extension;

  /// **Per-test.** The case directory this test replays in
  /// [RiscvRunMode.demo] — under [demoSignatures] for `riscv_arch`, under
  /// `formal.demo_outputs` for `riscv_formal`. Defaults to the test's
  /// `name` when absent.
  ///
  /// Shared between the two drivers on purpose: it names a case, and each
  /// driver resolves it inside its own corpus.
  final String? demoCase;

  /// The effective mode, defaulting to [RiscvRunMode.normal].
  RiscvRunMode get effectiveMode => mode ?? RiscvRunMode.normal;

  /// The effective signature block, with the `riscv_signature`
  /// [GoldenCompareProfile]'s conventional filenames as defaults.
  ///
  /// Those defaults are exactly what a `pass_fail: { type: golden_compare,
  /// profile: riscv_signature }` block with no explicit paths resolves to,
  /// so the driver writes the files the detector then reads. The detector's
  /// config is self-contained and never sees this block — agreement is by
  /// shared convention, and the importer emits both halves together.
  RiscvSignatureConfig get effectiveSignature =>
      signature ?? const RiscvSignatureConfig();

  /// Register width implied by [isa] (`rv64…` ⇒ 64, anything else ⇒ 32).
  int get xlen {
    final raw = isa?.toLowerCase();
    if (raw != null && raw.startsWith('rv64')) return 64;
    return 32;
  }

  /// `-mabi=` value implied by [xlen]. Soft-float ABIs, because the
  /// arch-test suite links no floating-point runtime.
  String get abi => xlen == 64 ? 'lp64' : 'ilp32';

  /// Returns a copy of this config with every unset field filled in from
  /// [parent]. This is one inheritance step.
  ///
  /// Applied four times per test — include file → project `defaults:` →
  /// suite → test — so a value declared once at the top is visible at the
  /// bottom unless a lower level overrode it. Nested blocks merge
  /// field-by-field rather than wholesale, so a suite that sets only
  /// `signature.word_size` keeps the project's `signature.dut`.
  RiscvConfig mergeOnto(RiscvConfig? parent) {
    if (parent == null) return this;
    return RiscvConfig(
      isa: isa ?? parent.isa,
      reference: reference?.mergeOnto(parent.reference) ?? parent.reference,
      archTest: archTest?.mergeOnto(parent.archTest) ?? parent.archTest,
      toolchain: toolchain?.mergeOnto(parent.toolchain) ?? parent.toolchain,
      target: target?.mergeOnto(parent.target) ?? parent.target,
      compile: compile?.mergeOnto(parent.compile) ?? parent.compile,
      riscof: riscof?.mergeOnto(parent.riscof) ?? parent.riscof,
      signature: signature?.mergeOnto(parent.signature) ?? parent.signature,
      formal: formal?.mergeOnto(parent.formal) ?? parent.formal,
      extensions: extensions ?? parent.extensions,
      mode: mode ?? parent.mode,
      demoSignatures: demoSignatures ?? parent.demoSignatures,
      testPath: testPath ?? parent.testPath,
      extension: extension ?? parent.extension,
      demoCase: demoCase ?? parent.demoCase,
    );
  }

  /// Returns the reasons this config cannot drive a run under
  /// [simulatorId], or an empty list when it can.
  ///
  /// Called by the loader **after** the four merge steps, because
  /// completeness is a property of the flattened config: a project that
  /// declares `target.command` in `defaults:` and `riscv.test` per test is
  /// perfectly valid, and validating each level in isolation would reject
  /// it. Every message is an unlocalized English literal, matching the rest
  /// of the loader's diagnostics (loader errors have no localization
  /// channel, and the RISC-V path does not invent one).
  ///
  /// [simulatorId] selects which driver's requirements apply: the two
  /// drivers share the block but need entirely different keys out of it.
  List<String> validateForRun({String simulatorId = kSimulatorId}) {
    if (simulatorId == kFormalSimulatorId) return _validateFormal();
    final problems = <String>[];
    switch (effectiveMode) {
      case RiscvRunMode.normal:
        if (target?.command == null || target!.command!.isEmpty) {
          problems.add(
            '`riscv.target.command` is required in `mode: normal` — it is '
            'the command that runs your DUT for one architectural test. Use '
            'the `{elf}` and `{signature}` placeholders, e.g. '
            '`command: [./my_core, --elf, "{elf}", --signature, '
            '"{signature}"]`.',
          );
        }
        if (compile?.command == null && testPath == null) {
          problems.add(
            '`riscv.test` is required in `mode: normal` — it names the '
            'architectural test source to cross-compile. The '
            'RiscvArchTestImporter writes one per emitted test.',
          );
        }
      case RiscvRunMode.demo:
        if (demoSignatures == null || demoSignatures!.isEmpty) {
          problems.add(
            '`riscv.demo_signatures` is required in `mode: demo` — it is '
            'the directory of committed pre-captured signature pairs the '
            'run replays. Nothing is spawned in demo mode, so there is no '
            'toolchain to fall back on.',
          );
        }
      case RiscvRunMode.riscofPassthrough:
        if (riscof?.command == null || riscof!.command!.isEmpty) {
          problems.add(
            '`riscv.riscof.command` is required in '
            '`mode: riscof_passthrough` — it is your existing RISCOF '
            'invocation. Note it is spawned once per test, so point it at a '
            'single test (RISCOF `--testfile`) rather than the whole suite.',
          );
        }
    }
    return problems;
  }

  /// Completeness rules for the `riscv_formal` driver.
  ///
  /// A `.sby` file (or a full `formal.command` override) in `normal`, a
  /// corpus in `demo`, and `riscof_passthrough` refused outright — RISCOF
  /// drives architectural tests and has nothing to say about a bounded
  /// proof, so silently accepting it would spawn a command that cannot
  /// produce a formal verdict.
  List<String> _validateFormal() {
    final problems = <String>[];
    final f = formal;
    switch (effectiveMode) {
      case RiscvRunMode.normal:
        final hasCommand = (f?.command ?? const <String>[]).isNotEmpty;
        if (!hasCommand && (f?.sbyFile == null || f!.sbyFile!.isEmpty)) {
          problems.add(
            '`riscv.formal.sby_file` is required in `mode: normal` — it '
            'names the generated SymbiYosys job for ONE bounded proof '
            "(riscv-formal's `checks/<check>.sby`). "
            'RiscvFormalCheckImporter writes one per emitted test. Set '
            '`riscv.formal.command` instead only if you drive `sby` through '
            'a wrapper.',
          );
        }
        if (!hasCommand &&
            (f?.checksDir == null || f!.checksDir!.isEmpty) &&
            (f?.sbyFile == null || !p.isAbsolute(f!.sbyFile!))) {
          problems.add(
            '`riscv.formal.checks_dir` is required in `mode: normal` unless '
            '`riscv.formal.sby_file` is absolute — it is the directory '
            '`sby` runs in, and the generated `.sby` files reference their '
            'sources relative to it.',
          );
        }
      case RiscvRunMode.demo:
        if (f?.demoOutputs == null || f!.demoOutputs!.isEmpty) {
          problems.add(
            '`riscv.formal.demo_outputs` is required in `mode: demo` — it '
            'is the directory of committed pre-captured SymbiYosys outputs '
            'the run replays. Nothing is spawned in demo mode, so there is '
            'no SymbiYosys to fall back on.',
          );
        }
      case RiscvRunMode.riscofPassthrough:
        problems.add(
          '`mode: riscof_passthrough` does not apply to the '
          '`$kFormalSimulatorId` driver — RISCOF drives architectural '
          'compatibility tests, not bounded proofs. Use `mode: normal` '
          '(SymbiYosys) or `mode: demo`.',
        );
    }
    return problems;
  }

  /// Returns a copy with the given fields replaced. Hand-written (there is
  /// no code generation in `domain/models/`).
  RiscvConfig copyWith({
    String? isa,
    RiscvReferenceConfig? reference,
    RiscvArchTestConfig? archTest,
    RiscvToolchainConfig? toolchain,
    RiscvTargetConfig? target,
    RiscvCompileConfig? compile,
    RiscvRiscofConfig? riscof,
    RiscvSignatureConfig? signature,
    RiscvFormalConfig? formal,
    List<String>? extensions,
    RiscvRunMode? mode,
    String? demoSignatures,
    String? testPath,
    String? extension,
    String? demoCase,
  }) {
    return RiscvConfig(
      isa: isa ?? this.isa,
      reference: reference ?? this.reference,
      archTest: archTest ?? this.archTest,
      toolchain: toolchain ?? this.toolchain,
      target: target ?? this.target,
      compile: compile ?? this.compile,
      riscof: riscof ?? this.riscof,
      signature: signature ?? this.signature,
      formal: formal ?? this.formal,
      extensions: extensions ?? this.extensions,
      mode: mode ?? this.mode,
      demoSignatures: demoSignatures ?? this.demoSignatures,
      testPath: testPath ?? this.testPath,
      extension: extension ?? this.extension,
      demoCase: demoCase ?? this.demoCase,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is RiscvConfig &&
        other.isa == isa &&
        other.reference == reference &&
        other.archTest == archTest &&
        other.toolchain == toolchain &&
        other.target == target &&
        other.compile == compile &&
        other.riscof == riscof &&
        other.signature == signature &&
        other.formal == formal &&
        riscvListEquals(other.extensions, extensions) &&
        other.mode == mode &&
        other.demoSignatures == demoSignatures &&
        other.testPath == testPath &&
        other.extension == extension &&
        other.demoCase == demoCase;
  }

  @override
  int get hashCode => Object.hash(
    isa,
    reference,
    archTest,
    toolchain,
    target,
    compile,
    riscof,
    signature,
    formal,
    extensions == null ? null : Object.hashAll(extensions!),
    mode,
    demoSignatures,
    testPath,
    extension,
    demoCase,
  );

  @override
  String toString() =>
      'RiscvConfig(isa: $isa, mode: ${mode?.wireName}, '
      'extension: $extension, test: $testPath)';
}

/// `riscv.reference:` — the golden model.
@immutable
class RiscvReferenceConfig {
  /// Creates a [RiscvReferenceConfig].
  const RiscvReferenceConfig({this.model, this.path, this.args});

  /// Which reference model. Defaults to [RiscvReferenceModel.spike] when
  /// unset — it is the easier of the two to obtain on every platform.
  final RiscvReferenceModel? model;

  /// Explicit path to the model binary. When null the driver resolves the
  /// model's conventional executable name against `$PATH`.
  final String? path;

  /// Extra arguments spliced in after the conventional flags and before
  /// the ELF path, for non-standard builds.
  final List<String>? args;

  /// The effective model, defaulting to Spike.
  RiscvReferenceModel get effectiveModel => model ?? RiscvReferenceModel.spike;

  /// Merges this block over [parent], field by field.
  RiscvReferenceConfig mergeOnto(RiscvReferenceConfig? parent) {
    if (parent == null) return this;
    return RiscvReferenceConfig(
      model: model ?? parent.model,
      path: path ?? parent.path,
      args: args ?? parent.args,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RiscvReferenceConfig &&
      other.model == model &&
      other.path == path &&
      riscvListEquals(other.args, args);

  @override
  int get hashCode =>
      Object.hash(model, path, args == null ? null : Object.hashAll(args!));
}

/// `riscv.arch_test:` — where the suite lives.
@immutable
class RiscvArchTestConfig {
  /// Creates a [RiscvArchTestConfig].
  const RiscvArchTestConfig({this.suitePath, this.revision});

  /// Root of a `riscv-arch-test` checkout.
  final String? suitePath;

  /// The suite's git SHA or tag. Carried onto results as
  /// `riscv.arch_test_revision`; the Pro compatibility report's provenance
  /// section is the consumer — "what was run, against what suite
  /// revision" is the feature of that artifact.
  final String? revision;

  /// Merges this block over [parent], field by field.
  RiscvArchTestConfig mergeOnto(RiscvArchTestConfig? parent) {
    if (parent == null) return this;
    return RiscvArchTestConfig(
      suitePath: suitePath ?? parent.suitePath,
      revision: revision ?? parent.revision,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RiscvArchTestConfig &&
      other.suitePath == suitePath &&
      other.revision == revision;

  @override
  int get hashCode => Object.hash(suitePath, revision);
}

/// `riscv.toolchain:` — the GNU cross-compiler.
@immutable
class RiscvToolchainConfig {
  /// Creates a [RiscvToolchainConfig].
  const RiscvToolchainConfig({this.prefix, this.path});

  /// Cross-compiler prefix, e.g. `riscv32-unknown-elf-`. Defaults to
  /// `riscv{xlen}-unknown-elf-` derived from the ISA string.
  final String? prefix;

  /// Directory holding the prefixed binaries. When null they are resolved
  /// against `$PATH` (augmented on macOS/Windows by `crux_io`'s
  /// `engineSearchDirs`, so a Homebrew install stays visible to a
  /// Finder-launched app).
  final String? path;

  /// Merges this block over [parent], field by field.
  RiscvToolchainConfig mergeOnto(RiscvToolchainConfig? parent) {
    if (parent == null) return this;
    return RiscvToolchainConfig(
      prefix: prefix ?? parent.prefix,
      path: path ?? parent.path,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RiscvToolchainConfig &&
      other.prefix == prefix &&
      other.path == path;

  @override
  int get hashCode => Object.hash(prefix, path);
}

/// `riscv.target:` — how to run the DUT for one test.
@immutable
class RiscvTargetConfig {
  /// Creates a [RiscvTargetConfig].
  const RiscvTargetConfig({this.command, this.pluginPath});

  /// Argv for one DUT run. Supports the placeholders documented on
  /// [expandRiscvPlaceholders]. The first element is the executable.
  ///
  /// This key is a **deliberate addition to RISCOF's shape**: RISCOF
  /// configures only `target.plugin_path` (a RISCOF *Python plugin*
  /// directory), and a Python plugin cannot be executed by a Dart driver
  /// without reimplementing RISCOF's plugin protocol. The primary path
  /// therefore runs the user's DUT directly, and `plugin_path` is retained
  /// for `mode: riscof_passthrough`, where RISCOF itself consumes it.
  final List<String>? command;

  /// RISCOF target-plugin directory. Passed through to the user's RISCOF
  /// invocation in `mode: riscof_passthrough`; unused by the primary path.
  final String? pluginPath;

  /// Merges this block over [parent], field by field.
  RiscvTargetConfig mergeOnto(RiscvTargetConfig? parent) {
    if (parent == null) return this;
    return RiscvTargetConfig(
      command: command ?? parent.command,
      pluginPath: pluginPath ?? parent.pluginPath,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RiscvTargetConfig &&
      riscvListEquals(other.command, command) &&
      other.pluginPath == pluginPath;

  @override
  int get hashCode => Object.hash(
    command == null ? null : Object.hashAll(command!),
    pluginPath,
  );
}

/// `riscv.compile:` — how to build one architectural test into an ELF.
@immutable
class RiscvCompileConfig {
  /// Creates a [RiscvCompileConfig].
  const RiscvCompileConfig({
    this.command,
    this.extraArgs,
    this.linkScript,
    this.includeDirs,
  });

  /// Full argv override. When set, the derived `gcc` command line is not
  /// built at all and this is used verbatim (after placeholder expansion).
  final List<String>? command;

  /// Arguments appended to the derived `gcc` command line.
  final List<String>? extraArgs;

  /// Linker script (`-T`). The arch-test environment supplies one per
  /// target plugin; omitted from the command line when null.
  final String? linkScript;

  /// Include directories (`-I`) — typically the suite's `env/` directory
  /// and the target plugin directory holding `model_test.h`.
  final List<String>? includeDirs;

  /// Merges this block over [parent], field by field.
  RiscvCompileConfig mergeOnto(RiscvCompileConfig? parent) {
    if (parent == null) return this;
    return RiscvCompileConfig(
      command: command ?? parent.command,
      extraArgs: extraArgs ?? parent.extraArgs,
      linkScript: linkScript ?? parent.linkScript,
      includeDirs: includeDirs ?? parent.includeDirs,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RiscvCompileConfig &&
      riscvListEquals(other.command, command) &&
      riscvListEquals(other.extraArgs, extraArgs) &&
      other.linkScript == linkScript &&
      riscvListEquals(other.includeDirs, includeDirs);

  @override
  int get hashCode => Object.hash(
    command == null ? null : Object.hashAll(command!),
    extraArgs == null ? null : Object.hashAll(extraArgs!),
    linkScript,
    includeDirs == null ? null : Object.hashAll(includeDirs!),
  );
}

/// `riscv.riscof:` — the user's own RISCOF invocation.
@immutable
class RiscvRiscofConfig {
  /// Creates a [RiscvRiscofConfig].
  const RiscvRiscofConfig({this.command, this.pythonBinary});

  /// Argv spawned once per test in [RiscvRunMode.riscofPassthrough].
  final List<String>? command;

  /// Python interpreter used only by the toolchain probe to report the
  /// RISCOF version. Defaults to `riscof` on `$PATH`.
  final String? pythonBinary;

  /// Merges this block over [parent], field by field.
  RiscvRiscofConfig mergeOnto(RiscvRiscofConfig? parent) {
    if (parent == null) return this;
    return RiscvRiscofConfig(
      command: command ?? parent.command,
      pythonBinary: pythonBinary ?? parent.pythonBinary,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RiscvRiscofConfig &&
      riscvListEquals(other.command, command) &&
      other.pythonBinary == pythonBinary;

  @override
  int get hashCode => Object.hash(
    command == null ? null : Object.hashAll(command!),
    pythonBinary,
  );
}

/// `riscv.signature:` — where the two dumps land and how wide a word is.
@immutable
class RiscvSignatureConfig {
  /// Creates a [RiscvSignatureConfig].
  const RiscvSignatureConfig({this.dut, this.reference, this.wordSize});

  /// The **declared** DUT dump path, or null when the profile's convention
  /// is in force. Nullable rather than defaulted so [mergeOnto] and the
  /// loader's `dut == reference` guard can tell "declared" from "defaulted"
  /// — a suite that sets only `reference:` must not silently pin `dut:`.
  /// Read [effectiveDut] to get the path the driver actually uses.
  final String? dut;

  /// The **declared** reference dump path, or null. See [dut].
  final String? reference;

  /// Bytes per signature word.
  ///
  /// **This key has a real consumer here that it did not have on the
  /// detector**, which is why the `riscv_signature`
  /// [GoldenCompareProfile] deliberately omits it: the comparator counts
  /// *words* and never needs a width, but locating the divergent
  /// instruction does. The driver multiplies the comparator's word offset
  /// by this and emits `riscv.signature.byte_offset`, which is what the Pro
  /// signature diff viewer decodes at.
  final int? wordSize;

  /// DUT dump path the driver writes and the detector reads, relative to
  /// the test working directory unless absolute. Falls back to the
  /// `riscv_signature` profile's conventional filename, which is exactly
  /// what a `pass_fail: { type: golden_compare, profile: riscv_signature }`
  /// block with no explicit paths resolves to — that shared convention is
  /// how the two halves agree without the detector ever seeing this block.
  String get effectiveDut =>
      dut ?? GoldenCompareProfile.riscvSignature.defaultDutPath!;

  /// Reference dump path. Same defaulting rule as [effectiveDut].
  String get effectiveReference =>
      reference ?? GoldenCompareProfile.riscvSignature.defaultReferencePath!;

  /// The effective word size, defaulting to
  /// [RiscvConfig.kDefaultWordSize].
  int get effectiveWordSize => wordSize ?? RiscvConfig.kDefaultWordSize;

  /// Merges this block over [parent], field by field.
  RiscvSignatureConfig mergeOnto(RiscvSignatureConfig? parent) {
    if (parent == null) return this;
    return RiscvSignatureConfig(
      dut: dut ?? parent.dut,
      reference: reference ?? parent.reference,
      wordSize: wordSize ?? parent.wordSize,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RiscvSignatureConfig &&
      other.dut == dut &&
      other.reference == reference &&
      other.wordSize == wordSize;

  @override
  int get hashCode => Object.hash(dut, reference, wordSize);
}

/// `riscv.formal:` — the riscv-formal / SymbiYosys check set (one test per
/// job, applied to bounded proofs).
///
/// riscv-formal is *N* independent bounded proofs, one per generated
/// `.sby` file, each pass/fail with a counterexample VCD on failure. The
/// job model has no fan-out, so the enumeration happens **before** the
/// scheduler in [RiscvFormalCheckImporter] and this block carries the
/// per-test coordinates it wrote.
@immutable
class RiscvFormalConfig {
  /// Creates a [RiscvFormalConfig].
  const RiscvFormalConfig({
    this.checksDir,
    this.sbyBinary,
    this.command,
    this.demoOutputs,
    this.check,
    this.sbyFile,
    this.task,
    this.group,
  });

  /// Conventional `sby` executable name, used when [sbyBinary] is unset.
  static const String kDefaultSbyBinary = 'sby';

  /// Directory holding the generated `.sby` files — riscv-formal's
  /// `checks/` after `genchecks.py` has run.
  ///
  /// **This is also the directory `sby` is spawned in**, and that is not
  /// incidental: `genchecks.py` writes `[files]` entries relative to
  /// `checks/`, and the upstream `Makefile` runs `sby` from there. Using
  /// the SimCrux work directory as the cwd instead would break every
  /// generated file reference, so the driver overrides the cwd for this
  /// spawn and points `sby -d` at the work directory for its output.
  final String? checksDir;

  /// The SymbiYosys executable. Defaults to [kDefaultSbyBinary] on
  /// `$PATH` (augmented on macOS/Windows so a Finder-launched app still
  /// sees a Homebrew or OSS CAD Suite install).
  final String? sbyBinary;

  /// Full argv override, for users who drive `sby` through a wrapper.
  /// Supports the placeholders documented on [expandRiscvPlaceholders].
  /// When set, the derived `sby -f -d {task_dir} {sby_file}` line is not
  /// built at all.
  final List<String>? command;

  /// Root of the committed pre-captured SymbiYosys output corpus used by
  /// [RiscvRunMode.demo]. Each immediate subdirectory is one case.
  ///
  /// A separate key from [RiscvConfig.demoSignatures] because the two
  /// corpora are different shapes — signature pairs versus captured
  /// logs and traces — and a project may legitimately run both flows in
  /// demo mode at once.
  final String? demoOutputs;

  /// **Per-test.** The riscv-formal check name, e.g. `insn_add_ch0`.
  /// Rides into `TestResult.metrics` as `riscv.formal.check`.
  final String? check;

  /// **Per-test.** The `.sby` job file, relative to [checksDir] (or
  /// absolute). One file is one bounded proof.
  final String? sbyFile;

  /// **Per-test.** The `[tasks]` name to run, for a multi-task `.sby`.
  ///
  /// Normally empty: `genchecks.py` emits single-task files. When a file
  /// does declare tasks the importer emits one test per task and passes
  /// the name to `sby`, because a single invocation running every task
  /// would print several `DONE (…)` lines and re-create exactly the
  /// fan-out the one-test-per-job model exists to prevent.
  final String? task;

  /// **Per-test.** The property group the check belongs to (`insn`,
  /// `reg`, `pc_fwd`, `causal`, `liveness`, `unique`, `cover`, …).
  ///
  /// The formal analogue of `riscv.extension`: it is what the Pro formal
  /// dashboard's "coverage of the RVFI check set" rollup groups on.
  /// Written by the importer from the check name and editable afterwards,
  /// because the user owns the emitted YAML.
  final String? group;

  /// The `sby` executable to spawn.
  String get effectiveSbyBinary => sbyBinary ?? kDefaultSbyBinary;

  /// The group tag to report, falling back to one derived from [check].
  String? get effectiveGroup => group ?? groupForCheck(check);

  /// The RVFI channel index encoded in a check name (`…_ch0` ⇒ `0`), or
  /// null when the name carries none.
  String? get channel {
    final name = check;
    if (name == null) return null;
    final match = RegExp(r'_ch(\d+)$').firstMatch(name);
    return match?.group(1);
  }

  /// Derives the property group from a riscv-formal check name.
  ///
  /// `insn_add_ch0` ⇒ `insn`, `pc_fwd_ch0` ⇒ `pc_fwd`, `reg_ch0` ⇒
  /// `reg`. Pure, and shared by the importer and the driver so a
  /// hand-written config with no `group:` still groups the same way the
  /// importer would have.
  static String? groupForCheck(String? check) {
    if (check == null || check.isEmpty) return null;
    var name = check.replaceFirst(RegExp(r'_ch\d+$'), '');
    // riscv-formal's own naming: `insn_<mnemonic>`, `csrw_<csr>`,
    // `csrc_<csr>`, `csrr_<csr>` are per-instruction / per-CSR families;
    // everything else (`reg`, `pc_fwd`, `pc_bwd`, `liveness`, `unique`,
    // `causal`, `cover`, `hang`, `ill`) is already the group.
    for (final family in const ['insn', 'csrw', 'csrc', 'csrr', 'csrs']) {
      if (name.startsWith('${family}_')) return family;
    }
    // A trailing numeric suffix on an otherwise plain name (`cover_2`)
    // is an index, not a group.
    name = name.replaceFirst(RegExp(r'_\d+$'), '');
    return name.isEmpty ? null : name;
  }

  /// Returns a copy with the given fields replaced. Hand-written (there is
  /// no code generation in `domain/models/`).
  RiscvFormalConfig copyWith({
    String? checksDir,
    String? sbyBinary,
    List<String>? command,
    String? demoOutputs,
    String? check,
    String? sbyFile,
    String? task,
    String? group,
  }) {
    return RiscvFormalConfig(
      checksDir: checksDir ?? this.checksDir,
      sbyBinary: sbyBinary ?? this.sbyBinary,
      command: command ?? this.command,
      demoOutputs: demoOutputs ?? this.demoOutputs,
      check: check ?? this.check,
      sbyFile: sbyFile ?? this.sbyFile,
      task: task ?? this.task,
      group: group ?? this.group,
    );
  }

  /// Merges this block over [parent], field by field.
  RiscvFormalConfig mergeOnto(RiscvFormalConfig? parent) {
    if (parent == null) return this;
    return RiscvFormalConfig(
      checksDir: checksDir ?? parent.checksDir,
      sbyBinary: sbyBinary ?? parent.sbyBinary,
      command: command ?? parent.command,
      demoOutputs: demoOutputs ?? parent.demoOutputs,
      check: check ?? parent.check,
      sbyFile: sbyFile ?? parent.sbyFile,
      task: task ?? parent.task,
      group: group ?? parent.group,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RiscvFormalConfig &&
      other.checksDir == checksDir &&
      other.sbyBinary == sbyBinary &&
      riscvListEquals(other.command, command) &&
      other.demoOutputs == demoOutputs &&
      other.check == check &&
      other.sbyFile == sbyFile &&
      other.task == task &&
      other.group == group;

  @override
  int get hashCode => Object.hash(
    checksDir,
    sbyBinary,
    command == null ? null : Object.hashAll(command!),
    demoOutputs,
    check,
    sbyFile,
    task,
    group,
  );
}

/// Substitutes `{…}` placeholders in one argv element.
///
/// Recognized placeholders, all optional:
///
/// | Placeholder | Meaning |
/// |---|---|
/// | `{elf}` | absolute path to the cross-compiled test ELF |
/// | `{signature}` | absolute path the DUT must write its signature to |
/// | `{ref_signature}` | absolute path of the reference signature |
/// | `{test}` | the architectural test source path |
/// | `{isa}` | the configured ISA string |
/// | `{name}` | the SimCrux test name |
/// | `{work_dir}` | the per-test working directory |
/// | `{sby_file}` | absolute path to the `.sby` job file (formal) |
/// | `{task_dir}` | absolute path `sby -d` writes its task directory to (formal) |
/// | `{task}` | the `[tasks]` name, or empty (formal) |
/// | `{check}` | the riscv-formal check name (formal) |
/// | `{checks_dir}` | the directory holding the `.sby` files (formal) |
///
/// An unknown placeholder is left verbatim rather than blanked, so a typo
/// surfaces in the spawned command line (and in the log) instead of
/// silently becoming an empty argument.
String expandRiscvPlaceholders(String arg, Map<String, String> values) {
  return arg.replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) {
    final key = m.group(1)!;
    return values[key] ?? m.group(0)!;
  });
}

/// List equality helper shared by the `riscv:` value objects. Mirrors the
/// hand-written helpers in `test_spec.dart` rather than pulling in
/// `collection` for four call sites.
bool riscvListEquals<T>(List<T>? a, List<T>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
