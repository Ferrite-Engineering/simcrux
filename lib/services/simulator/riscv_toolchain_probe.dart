// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/riscv_host_platform.dart';
import 'package:simcrux/domain/enums/riscv_reference_model.dart';
import 'package:simcrux/domain/enums/riscv_run_mode.dart';
import 'package:simcrux/domain/enums/riscv_toolchain_component.dart';
import 'package:simcrux/domain/models/riscv_config.dart';
import 'package:simcrux/domain/models/riscv_toolchain_report.dart';

/// Signature of the non-throwing version probe the driver already owns.
/// Matches `ProcessBackedSimulatorDriver.detectVersionOf`, which consults
/// **both** stdout and stderr (toolchains disagree about which one carries
/// the banner) and returns null rather than throwing on any failure.
typedef RiscvVersionProbe =
    Future<String?> Function(
      String binary, {
      List<String> versionArgs,
    });

/// Locates the RISC-V toolchain and says what to do about whatever is
/// missing.
///
/// ## Posture: detect and guide, never bundle
///
/// SimCrux locates what the user installed and spawns it, exactly as it
/// does for Icarus, Verilator and GHDL. Nothing is bundled and nothing is
/// auto-installed. Bundling a GPL engine alongside SimCrux is mere
/// aggregation and does not change SimCrux's licence, but it does **not**
/// reduce what we owe when we ship the binary — pinned upstream provenance with
/// SHA-256, patches preserved as first-class artifacts, Corresponding
/// Source published beside the binary and retained for the binary's whole
/// lifetime, and a per-licence delivery mechanism. The RISC-V dependency
/// set is the heaviest in the suite and we build none of it, so bundling it
/// would take on that obligation for four components we do not control.
/// **SimCrux conveys none of it, so none of those obligations arise.**
///
/// ## Why this is not `detectVersion`
///
/// `SimulatorDriver.detectVersion` returns one `String?`. That is right for
/// Icarus and wrong here: there are four independent dependencies and "not
/// found" has a different answer for each. This probe reports per
/// component; `RiscvArchDriver.detectVersion` is implemented on top of it
/// and returns [RiscvToolchainReport.summaryLine], so the existing
/// interface is honored without pretending four dependencies are one.
///
/// ## Windows is stated plainly
///
/// Where the honest answer is "use WSL2", the guidance says that. Emitting
/// a Windows invocation we know is broken, and letting the user find out
/// through a subprocess failure at depth, is a worse product than a clear
/// sentence.
class RiscvToolchainProbe {
  /// Creates a [RiscvToolchainProbe].
  ///
  /// [versionProbe] is the driver's own `detectVersionOf`, injected rather
  /// than reimplemented so there is exactly one non-throwing spawn-and-read
  /// path in the codebase. [platform] defaults to the host and is injected
  /// by tests so all three platforms' guidance is covered from one runner.
  RiscvToolchainProbe({
    required RiscvVersionProbe versionProbe,
    RiscvHostPlatform? platform,
    // Initializing formals cannot name a private field; the field is
    // intentionally private.
    // ignore: prefer_initializing_formals
  }) : _versionProbe = versionProbe,
       platform =
           platform ??
           RiscvHostPlatform.fromFlags(
             isMacOS: Platform.isMacOS,
             isWindows: Platform.isWindows,
           );

  final RiscvVersionProbe _versionProbe;

  /// The host platform the guidance is phrased for.
  final RiscvHostPlatform platform;

  /// Probes every component [config] could need and returns the report.
  ///
  /// **Returns an empty report in [RiscvRunMode.demo] without probing
  /// anything.** Demo mode spawns nothing, so there is no component whose
  /// absence is a defect. This is a deliberate skip rather than
  /// probe-and-tolerate: a probe that fires and is then ignored costs four
  /// process spawns per diagnostics open and invites a future reader to
  /// "fix" the ignored result into a failure.
  ///
  /// Non-throwing end to end — every spawn goes through [_versionProbe],
  /// which swallows `ProcessException` and a non-zero exit alike.
  Future<RiscvToolchainReport> probe(RiscvConfig config) async {
    if (config.effectiveMode == RiscvRunMode.demo) {
      return RiscvToolchainReport(components: const <RiscvComponentReport>[]);
    }
    final components = <RiscvComponentReport>[
      await _probeCrossCompiler(config),
      await _probeReferenceModel(config),
      await _probeRiscof(config),
      await _probeFormalEngine(config),
    ];
    return RiscvToolchainReport(components: components);
  }

  // ── per-component probes ───────────────────────────────────────────

  Future<RiscvComponentReport> _probeCrossCompiler(RiscvConfig config) async {
    final binary = crossCompilerBinary(config);
    final version = await _versionProbe(
      binary,
      versionArgs: const ['--version'],
    );
    return RiscvComponentReport(
      component: RiscvToolchainComponent.crossCompiler,
      binary: binary,
      found: version != null,
      version: version,
      remediation: version != null
          ? null
          : remediationFor(RiscvToolchainComponent.crossCompiler, config),
    );
  }

  Future<RiscvComponentReport> _probeReferenceModel(RiscvConfig config) async {
    final binary = referenceModelBinary(config);
    // Spike answers `--help` on stderr and exits 0; Sail's emulator prints
    // its banner for `--help` too. `--version` is not universal across
    // either project's builds, so `--help` is the probe that actually
    // distinguishes "installed" from "absent".
    final version = await _versionProbe(binary, versionArgs: const ['--help']);
    return RiscvComponentReport(
      component: RiscvToolchainComponent.referenceModel,
      binary: binary,
      found: version != null,
      version: version,
      remediation: version != null
          ? null
          : remediationFor(RiscvToolchainComponent.referenceModel, config),
    );
  }

  Future<RiscvComponentReport> _probeRiscof(RiscvConfig config) async {
    final binary = config.riscof?.pythonBinary ?? 'riscof';
    final version = await _versionProbe(
      binary,
      versionArgs: const ['--version'],
    );
    return RiscvComponentReport(
      component: RiscvToolchainComponent.pythonRiscof,
      binary: binary,
      found: version != null,
      version: version,
      remediation: version != null
          ? null
          : remediationFor(RiscvToolchainComponent.pythonRiscof, config),
    );
  }

  Future<RiscvComponentReport> _probeFormalEngine(RiscvConfig config) async {
    const binary = 'sby';
    final version = await _versionProbe(
      binary,
      versionArgs: const ['--version'],
    );
    return RiscvComponentReport(
      component: RiscvToolchainComponent.formalEngine,
      binary: binary,
      found: version != null,
      version: version,
      remediation: version != null
          ? null
          : remediationFor(RiscvToolchainComponent.formalEngine, config),
    );
  }

  // ── binary resolution ──────────────────────────────────────────────

  /// The `gcc` the cross-compile stage will invoke, honoring
  /// `riscv.toolchain.prefix` / `.path` and otherwise deriving
  /// `riscv{32,64}-unknown-elf-gcc` from the ISA string.
  static String crossCompilerBinary(RiscvConfig config) {
    final prefix =
        config.toolchain?.prefix ?? 'riscv${config.xlen}-unknown-elf-';
    final name = '${prefix}gcc';
    final dir = config.toolchain?.path;
    if (dir == null || dir.isEmpty) return name;
    return p.join(dir, name);
  }

  /// The reference-model binary the compile stage will invoke, honoring
  /// `riscv.reference.path` and otherwise using the model's conventional
  /// executable name for this XLEN.
  static String referenceModelBinary(RiscvConfig config) {
    final explicit = config.reference?.path;
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final model = config.reference?.effectiveModel ?? RiscvReferenceModel.spike;
    return model.defaultBinary(xlen: config.xlen);
  }

  // ── guidance ───────────────────────────────────────────────────────

  /// The actionable, per-platform remediation for [component].
  ///
  /// Unlocalized English on purpose — this is the same channel as
  /// `SimulatorNotAvailableException.remediation`, and it is what reaches
  /// logs and `failureMessage`. The diagnostics panel renders localized
  /// copy of its own (`RiscvToolchainReportView`).
  ///
  /// Exposed (rather than private) so the widget's locale sweep can assert
  /// that the localized strings cover exactly the same component × platform
  /// matrix this method does.
  String remediationFor(
    RiscvToolchainComponent component,
    RiscvConfig config,
  ) {
    switch (component) {
      case RiscvToolchainComponent.crossCompiler:
        return _crossCompilerGuidance(config);
      case RiscvToolchainComponent.referenceModel:
        return _referenceModelGuidance(config);
      case RiscvToolchainComponent.pythonRiscof:
        return _riscofGuidance();
      case RiscvToolchainComponent.formalEngine:
        return _formalGuidance();
    }
  }

  String _crossCompilerGuidance(RiscvConfig config) {
    final binary = crossCompilerBinary(config);
    const settingsHint =
        'Set `riscv.toolchain.path` in your simcrux.yaml if it is installed '
        'somewhere off PATH.';
    switch (platform) {
      case RiscvHostPlatform.linux:
        return 'The RISC-V GNU cross-compiler `$binary` was not found. '
            'Install your distribution package (Debian/Ubuntu: '
            '`gcc-riscv64-unknown-elf`; Fedora: '
            '`riscv64-elf-gcc`; Arch: `riscv64-elf-gcc`), or unpack an xPack '
            'or SiFive prebuilt toolchain. $settingsHint';
      case RiscvHostPlatform.macos:
        return 'The RISC-V GNU cross-compiler `$binary` was not found. '
            'Install it with `brew tap riscv-software-src/riscv` then '
            '`brew install riscv-gnu-toolchain`, or unpack an xPack prebuilt. '
            'Note that an app launched from Finder does not inherit your '
            "shell's PATH, so a Homebrew install can be invisible even though "
            '`which $binary` works in a terminal — relaunch SimCrux from a '
            'terminal or set an explicit path. $settingsHint';
      case RiscvHostPlatform.windows:
        return 'The RISC-V GNU cross-compiler `$binary` was not found. '
            'Windows is the least well-trodden path for this toolchain: '
            'prebuilt cross-compilers do exist (xPack '
            '`@xpack-dev-tools/riscv-none-elf-gcc`, installed via npm or as a '
            'standalone archive) and they work, but the common target-plugin '
            'and linker-script assumptions in riscv-arch-test are written for '
            'a POSIX layout. Running the whole flow under WSL2 is the '
            'better-supported option. $settingsHint';
    }
  }

  String _referenceModelGuidance(RiscvConfig config) {
    final model = config.reference?.effectiveModel ?? RiscvReferenceModel.spike;
    final binary = referenceModelBinary(config);
    const settingsHint =
        'Set `riscv.reference.path` in your simcrux.yaml to point at the '
        'binary, or switch `riscv.reference.model` to the other model.';
    switch (platform) {
      case RiscvHostPlatform.linux:
        return model == RiscvReferenceModel.sail
            ? 'The Sail reference model `$binary` was not found. Build it from '
                  '`riscv/sail-riscv` (needs opam + the Sail compiler), or '
                  'download a release build. Spike is the easier of the two to '
                  'obtain if you do not specifically need Sail. $settingsHint'
            : 'The Spike ISA simulator `$binary` was not found. Build it from '
                  '`riscv-software-src/riscv-isa-sim`, or install your '
                  "distribution's `spike` / `riscv-isa-sim` package. "
                  '$settingsHint';
      case RiscvHostPlatform.macos:
        return model == RiscvReferenceModel.sail
            ? 'The Sail reference model `$binary` was not found. It builds on '
                  'macOS but takes effort (opam + the Sail compiler + a GNU '
                  'make). Spike is markedly easier here — '
                  '`brew tap riscv-software-src/riscv` then '
                  '`brew install riscv-isa-sim`. Also note that an app '
                  "launched from Finder does not inherit your shell's PATH. "
                  '$settingsHint'
            : 'The Spike ISA simulator `$binary` was not found. Install it '
                  'with `brew tap riscv-software-src/riscv` then '
                  '`brew install riscv-isa-sim`. An app launched from Finder '
                  "does not inherit your shell's PATH, so a Homebrew install "
                  'can be invisible even though `which $binary` works in a '
                  'terminal. $settingsHint';
      case RiscvHostPlatform.windows:
        return model == RiscvReferenceModel.sail
            ? 'The Sail reference model `$binary` was not found, and Sail is '
                  'not practically available as a native Windows build — '
                  'SimCrux is not going to pretend otherwise by spawning a '
                  'command that cannot work. Run the flow under WSL2, or '
                  'switch `riscv.reference.model` to `spike`, which does have '
                  'usable Windows builds (the OSS CAD Suite ships one). '
                  '$settingsHint'
            : 'The Spike ISA simulator `$binary` was not found. On Windows the '
                  'practical sources are the OSS CAD Suite bundle or a WSL2 '
                  'build. $settingsHint';
    }
  }

  String _riscofGuidance() {
    const common =
        'RISCOF is only needed for `mode: riscof_passthrough`; the default '
        '`mode: normal` drives the flow itself and does not require it.';
    switch (platform) {
      case RiscvHostPlatform.linux:
      case RiscvHostPlatform.macos:
        return 'RISCOF was not found. Install it into a virtualenv — '
            '`python3 -m venv .venv && . .venv/bin/activate && '
            'pip install riscof` — and either activate that venv before '
            'launching SimCrux or point `riscv.riscof.command` at '
            '`.venv/bin/riscof`. $common';
      case RiscvHostPlatform.windows:
        return 'RISCOF was not found. It installs cleanly on Windows — '
            r'`py -m venv .venv`, `.venv\Scripts\activate`, '
            '`pip install riscof` — and this is the one component of the four '
            'that Windows handles without drama. Point '
            r'`riscv.riscof.command` at `.venv\Scripts\riscof.exe` if '
            'SimCrux was launched outside the venv. $common';
    }
  }

  String _formalGuidance() {
    const common =
        'SymbiYosys is only needed for the riscv-formal driver; '
        'architectural-compatibility runs do not use it.';
    switch (platform) {
      case RiscvHostPlatform.linux:
        return 'SymbiYosys (`sby`) was not found. The OSS CAD Suite bundle '
            'ships Yosys, SymbiYosys and the SMT solvers together and is the '
            'least painful route. $common';
      case RiscvHostPlatform.macos:
        return 'SymbiYosys (`sby`) was not found. Install the OSS CAD Suite '
            'bundle, or `brew install yosys` plus SymbiYosys from source. '
            "An app launched from Finder does not inherit your shell's PATH. "
            '$common';
      case RiscvHostPlatform.windows:
        return 'SymbiYosys (`sby`) was not found. The OSS CAD Suite ships a '
            'Windows build; WSL2 is also common for this one. $common';
    }
  }
}
