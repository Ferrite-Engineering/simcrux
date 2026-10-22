// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

// The Flutter-free barrel: ConfigLoader sits inside the headless CLI's
// import closure (`SimcruxCli` → `CiRunner` → here), and the main
// `crux_license.dart` barrel drags `dart:ui`, which kills
// `dart build cli` inside the FFI transformer. Same symbols
// (LicenseTier / FeatureGate / kBetaPeriod) — see that barrel's doc.
import 'package:crux_flow/crux_flow.dart' show FlowKind;
import 'package:crux_license/crux_license_core.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/golden_compare_profile.dart';
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/riscv_reference_model.dart';
import 'package:simcrux/domain/enums/riscv_run_mode.dart';
import 'package:simcrux/domain/enums/waveform_capture_policy.dart';
import 'package:simcrux/domain/enums/waveform_format.dart';
import 'package:simcrux/domain/models/config_loader_error.dart';
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/domain/models/flow_tool_settings.dart';
import 'package:simcrux/domain/models/formal_config.dart';
import 'package:simcrux/domain/models/output_config.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/domain/models/pass_fail_config_codec.dart';
import 'package:simcrux/domain/models/project_identity.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/resource_lock.dart';
import 'package:simcrux/domain/models/riscv_config.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/simulator_policy.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/domain/models/waveform_policy.dart';
import 'package:simcrux/services/config/filelist_expander.dart';
import 'package:simcrux/services/config/mixed_language_validator.dart';
import 'package:simcrux/services/config/project_output_path.dart';
import 'package:simcrux/services/config/test_spec_expander.dart';
import 'package:simcrux/services/flow/flow_run_importer.dart';
import 'package:simcrux/services/formal/formal_containment.dart';
import 'package:yaml/yaml.dart';

// The id rule is domain vocabulary shared with the headless CLI; re-exported
// so readers of the loader see it beside `readProjectId`.
export 'package:simcrux/domain/models/project_identity.dart';

// The section parsers live in sibling part files. Each owns one slice
// of the `simcrux.yaml` schema; the [ConfigLoader] class below is the
// orchestrator that walks the top-level document and delegates each
// subtree to the matching reader:
//
//   - config_loader_readers.dart   — primitive scalar/list/map readers
//   - config_loader_sources.dart   — `sources:` (+ `_SourcesParsed`)
//   - config_loader_sweeps.dart    — `parameters:` / `seeds:` sweeps
//   - config_loader_pass_fail.dart — `pass_fail:` detectors
//   - config_loader_sections.dart  — `output:` / `waveform:` /
//                                     `simulators:` / `resources:`
//   - config_loader_riscv.dart     — `riscv:`
//   - config_loader_formal.dart    — `formal:` (the `sby` driver)
//   - config_loader_flow.dart      — `flow:` (implementation flows)
part 'config_loader_readers.dart';
part 'config_loader_sources.dart';
part 'config_loader_sweeps.dart';
part 'config_loader_pass_fail.dart';
part 'config_loader_sections.dart';
part 'config_loader_riscv.dart';
part 'config_loader_formal.dart';
part 'config_loader_flow.dart';

/// Default upper bound on the cartesian-product fan-out one
/// parameterized [TestSpec] template may produce.
///
/// At 10 000 expanded specs a project author has almost certainly
/// produced a configuration error (an unintended `seeds: [1..N]`
/// combined with a parameter sweep) rather than a deliberate sweep
/// they want to run. The loader rejects oversized expansions with a
/// structured error so the author sees the explosion before the
/// scheduler starts launching simulator processes.
///
/// The Pro-overlay `Settings → Test Execution → Parameterization`
/// surface exposes a user-editable override; the loader reads the
/// effective value from its constructor.
const int kDefaultMaxExpansionSize = 10000;

/// The Settings route the loader's project-tooling diagnostics send the
/// user down, as the Settings screen spells it in English.
///
/// Literals, because the loader is in the headless CLI's Flutter-free
/// import closure and has no localization channel. They are held to the
/// app's own strings by `config_loader_settings_labels_test.dart`, which
/// compares each with its `app_en.arb` value: a diagnostic that names a
/// control the Settings screen does not have is a dead end for the user
/// it is written for.
///
/// The rail category, not the group inside it: every engine's binary path
/// and the project-tooling switch are in Settings → Engines, whichever of
/// its groups (Simulators, Formal tools, Implementation flow) holds them.
const String kSettingsEnginesRoute = 'Settings → Engines';

/// The Settings → Engines switch that lets project files choose binaries
/// and environment (`settingsAllowProjectDefinedToolingLabel`).
const String kAllowProjectToolingControlLabel =
    'Let project files choose simulator binaries and environment';

/// The per-engine Settings → Engines path field
/// (`settingsSimulatorBinaryLabel`).
const String kSimulatorBinaryPathControlLabel = 'Binary path';

/// Where to turn on project-defined tooling, in both front ends — the
/// sentence every gate diagnostic ends with.
const String kProjectToolingRemedy =
    'To trust project files on this machine, turn on '
    '$kSettingsEnginesRoute → "$kAllowProjectToolingControlLabel" in '
    'the app, or pass `--allow-project-tooling` to the CLI.';

/// Loads a `simcrux.yaml` project file into a [RegressionConfig].
///
/// - Read YAML from disk.
/// - Validate the top-level schema (`version`, `defaults`, `suites`,
///   optional `simulators`).
/// - Apply project-level `defaults:` down into each suite's tests,
///   and suite-level overrides on top of that (test-level overrides
///   win last).
/// - Surface every error with source span (`file:line:col`) when the
///   YAML parser preserved one.
/// - Resolve `includes:` across multiple files, expand `.f` Vivado
///   filelists, and expand `seeds:` / `parameters:` Cartesian sweeps.
///
/// Glob expansion for `sources:` is not supported.
///
/// The loader is pure-Dart and synchronous-ish (it does one async
/// file read). It does not touch the filesystem beyond reading the
/// project file. Source expansion belongs in a downstream service.
class ConfigLoader {
  /// Creates a [ConfigLoader].
  ///
  /// [readFile] is injected so tests can drive the loader off an
  /// in-memory string without touching the disk. The default
  /// implementation reads the file via `dart:io`.
  ///
  /// [simulatorLanguages] is the catalog used by the mixed-language
  /// compatibility validator. Keys are simulator ids; values are the
  /// set of HDL languages that simulator can handle natively. Defaults
  /// to the open-core built-in set (icarus, verilator, ghdl, cocotb).
  /// Pro-overlay tests can pass an extended catalog including vendor
  /// drivers. Pass an empty map to disable the mixed-language check.
  ConfigLoader({
    Future<String> Function(String path)? readFile,
    FilelistExpander? filelistExpander,
    Map<String, DetectorSpec> reusableDetectors =
        const <String, DetectorSpec>{},
    Map<String, Set<HdlLanguage>>? simulatorLanguages,
    LicenseTier licenseTier = LicenseTier.openCore,
    int maxExpansionSize = kDefaultMaxExpansionSize,
    bool betaPeriod = kBetaPeriod,
    bool allowProjectDefinedTooling = false,
    this.expander = const TestSpecExpander(),
    this.simulatorPolicy = SimulatorPolicy.none,
  }) : _readFile = readFile ?? _defaultReadFile,
       _filelistExpander =
           filelistExpander ?? FilelistExpander(readFile: readFile),
       _reusableDetectors = Map<String, DetectorSpec>.unmodifiable(
         reusableDetectors,
       ),
       _simulatorLanguages = simulatorLanguages ?? defaultSimulatorLanguages,
       // Initializing-formal alternatives would require dropping the
       // leading underscore on these fields (Dart's parser disallows
       // `this._licenseTier`), which is undesirable — the fields are
       // intentionally private.
       // ignore: prefer_initializing_formals
       _licenseTier = licenseTier,
       // Same rationale as `_licenseTier` above — private field.
       // ignore: prefer_initializing_formals
       _maxExpansionSize = maxExpansionSize,
       // Same rationale as `_licenseTier` above — private field.
       // ignore: prefer_initializing_formals
       _betaPeriod = betaPeriod,
       // Same rationale as `_licenseTier` above — private field.
       // ignore: prefer_initializing_formals
       _allowProjectDefinedTooling = allowProjectDefinedTooling;

  final Future<String> Function(String path) _readFile;
  final FilelistExpander _filelistExpander;
  final Map<String, DetectorSpec> _reusableDetectors;
  final Map<String, Set<HdlLanguage>> _simulatorLanguages;
  final LicenseTier _licenseTier;
  final int _maxExpansionSize;
  final bool _betaPeriod;

  /// Whether this loader honors **project-defined tooling** — the
  /// `simcrux.yaml` keys that decide which executable SimCrux spawns
  /// and under what environment:
  ///
  /// - `simulators.<id>.path`, `simulators.<id>.env` — dropped, with an
  ///   advisory;
  /// - `riscv.target.command`, `riscv.riscof.command`,
  ///   `riscv.compile.command`, `riscv.formal.command` — the load is
  ///   refused;
  /// - `riscv.reference.path`, `riscv.toolchain.path`,
  ///   `riscv.toolchain.prefix`, `riscv.riscof.binary`,
  ///   `riscv.formal.sby_binary` — dropped, with an advisory;
  /// - `formal.command`, `formal.extra_args` — the load is refused;
  /// - `formal.sby_binary`, `formal.eqy_binary`, `formal.ghdl_binary`,
  ///   `formal.tools.<tool>` — dropped, with an advisory;
  /// - `flow.entries[].fusesoc`, `flow.entries[].extra_args`,
  ///   `flow.entries[].handoff` — the load is refused;
  /// - `flow.entries[].launcher`, `flow.entries[].librelane_binary`,
  ///   `flow.entries[].docker_image`, `flow.entries[].fusesoc.binary` —
  ///   dropped, with an advisory;
  /// - `output.results_path`, `output.summary_path` outside the project
  ///   directory — the load is refused.
  ///
  /// The first three are every key that chooses a spawned process's argv[0]
  /// or environment, and each is arbitrary code execution on the machine
  /// that opens the file. The last is where a `--ci` run creates and
  /// truncates files, which outside the project is any file the user can
  /// write. A project file is untrusted input:
  /// `.yaml` / `.yml` are registered SimCrux document types, so one arrives
  /// by double-click, by `git clone`, or by download. Default **false**.
  /// What the gate does not cover, and cannot: running a project's tests
  /// runs the project's own code (a cocotb Makefile and Python module, a
  /// Verilator C++ harness, a `.sby` job), which is why opening a file never
  /// runs it unless the user asked for that (`autoRunOnOpen`, default off).
  ///
  /// The app passes the user's Settings → Engines
  /// [kAllowProjectToolingControlLabel] switch (default off); the CLI,
  /// which has no Settings to read, passes `--allow-project-tooling`.
  /// Either way a human made the decision, which is the whole point.
  ///
  /// This is deliberately coarse — one machine-wide switch, not a
  /// per-project trust record — because no workspace-trust concept
  /// exists anywhere in the suite yet. When one lands it replaces this
  /// flag's *source*, not its meaning.
  final bool _allowProjectDefinedTooling;

  /// Pure expander used to fan parameterized templates into concrete
  /// child specs. Exposed as a constructor parameter so tests can
  /// inject a counting/spy expander without subclassing the loader.
  final TestSpecExpander expander;

  /// The organization's simulator policy: the fallback simulator for a test
  /// the project file gives none, and the allow-list every test's simulator
  /// is checked against. [SimulatorPolicy.none] in open core.
  ///
  /// The fallback is the last level of the simulator lookup, below the
  /// test, its suite, and `defaults.simulator` (this file's or an including
  /// file's), so the project file always wins. The allow-list is checked
  /// after that lookup, against whichever id won.
  final SimulatorPolicy simulatorPolicy;

  /// The load error for a test whose simulator the organization's
  /// allow-list does not include. Exposed so tests can assert a stable
  /// message.
  static String simulatorNotAllowedMessage({
    required String testId,
    required String simulatorId,
    required Set<String> allowed,
  }) {
    final names = allowed.toList()..sort();
    final list = names.isEmpty ? 'none' : names.join(', ');
    return 'Test `$testId` uses simulator `$simulatorId`, which your '
        "organization's policy (simulatorBinaryPolicy) does not allow on "
        'this machine. Allowed simulators: $list.';
  }

  /// Returns the user-suggested guidance string when a `seeds:` /
  /// `parameters:` sweep is rejected because the active license tier
  /// does not unlock parameterization. Exposed so tests can assert
  /// against a stable message.
  static String parameterizationGateMessage(String field) {
    return 'Test parameterization (`$field:` sweep) requires SimCrux '
        'Pro. The sweep block was ignored and the test will run once '
        'with the literal value (or no seed) instead.';
  }

  /// True when the active configuration unlocks `seeds:` and
  /// `parameters:` sweep expansion. The beta-period short-circuit
  /// keeps every gate open while `kBetaPeriod = true`, so under
  /// default beta semantics this is `true` regardless of
  /// [_licenseTier]. Once `kBetaPeriod` is `false` the
  /// gate consults the `featureEquivalent` mapping; Open Core users
  /// see the warning and the sweep is skipped, Pro / EDU / Enterprise
  /// users see the sweep expand normally.
  ///
  /// Mirrors `FeatureGate.isAvailable` semantics but takes
  /// [_betaPeriod] as a constructor-time injection so tests can flip
  /// it without touching the global `kBetaPeriod`.
  bool get _parameterizationUnlocked {
    if (_betaPeriod) return true;
    return _licenseTier.featureEquivalent.index >= LicenseTier.pro.index;
  }

  /// Default simulator-language catalog used when the caller does not
  /// pass one. Matches the open-core driver registry's declared
  /// `SimulatorCapabilities.supportedLanguages`. Cocotb is omitted
  /// here because [MixedLanguageValidator] special-cases its language
  /// coverage to the union of its possible backends.
  static const Map<String, Set<HdlLanguage>> defaultSimulatorLanguages = {
    'icarus': {HdlLanguage.verilog, HdlLanguage.systemVerilog},
    'verilator': {HdlLanguage.verilog, HdlLanguage.systemVerilog},
    'ghdl': {HdlLanguage.vhdl},
  };

  /// The lone schema version the loader accepts. A schema
  /// bump triggers a structured migration error; we do not silently
  /// accept newer versions.
  static const String supportedSchemaVersion = '1';

  // There is deliberately no built-in default simulator id. A test that
  // inherits no `simulator:` from `defaults:` or its suite is a load error
  // naming the test, because a silent `icarus` would run a VHDL, cocotb or
  // RISC-V test under an engine its author never chose and report the
  // failure as the design's. An organization can name one
  // ([SimulatorPolicy.fallbackSimulatorId]); that is a decision somebody
  // made, which a compiled-in guess is not.

  /// Default per-test timeout when the project file does not specify
  /// one. Mirrors `RegressionRequest.defaultTimeout` so the scheduler
  /// fallback and the loader fallback agree.
  static const Duration defaultTimeout = Duration(seconds: 300);

  static Future<String> _defaultReadFile(String path) =>
      File(path).readAsString();

  /// Loads and validates the project file at [path]. Resolves
  /// `includes:` recursively and expands any `.f` filelist entries
  /// in `sources:`. Throws a [ConfigLoaderException] containing every
  /// detected error when validation fails.
  Future<RegressionConfig> load(String path) async {
    final absPath = p.normalize(p.absolute(path));
    final loaded = await _loadInternal(absPath, visited: <String>{});
    final flowEntries = loaded.flow?.entries ?? const <FlowEntry>[];
    // A project whose only work is its `flow:` entries loads: the entries
    // become the synthesised `flow` suite below.
    if (loaded.suites.isEmpty && flowEntries.isEmpty) {
      throw ConfigLoaderException([
        ConfigLoaderError.generic(
          path: absPath,
          message:
              'No suites found — declare at least one suite or a `flow:` '
              'entry in the project file or in an included file.',
        ),
      ]);
    }
    final flowErrors = _flowLoadErrors(loaded, absPath);
    if (flowErrors.isNotEmpty) throw ConfigLoaderException(flowErrors);
    final expanded = _withFlowSuite(await _expandFilelistsInConfig(loaded));

    // Mixed-language compatibility check: walk every test
    // and verify the configured simulator can handle every source's
    // language. The validator special-cases Cocotb (its declared
    // `python` capability + its underlying-simulator coverage) and
    // skips tests whose simulator id isn't in the catalog (those are
    // reported by a separate validator path).
    if (_simulatorLanguages.isNotEmpty) {
      final validator = MixedLanguageValidator(
        simulatorLanguages: _simulatorLanguages,
      );
      final allTests = expanded.suites.expand((s) => s.tests);
      final errors = validator.validate(
        tests: allTests,
        configFilePath: absPath,
      );
      if (errors.isNotEmpty) throw ConfigLoaderException(errors);
    }

    return expanded;
  }

  /// The errors the merged `flow:` block can only show once every included
  /// file is read: an entry name declared in two files, a suite that takes
  /// the reserved [FlowRunImporter.kFlowSuiteName], and a LibreLane
  /// configuration outside the project directory.
  List<ConfigLoaderError> _flowLoadErrors(
    RegressionConfig config,
    String path,
  ) {
    final entries = config.flow?.entries ?? const <FlowEntry>[];
    if (entries.isEmpty) return const <ConfigLoaderError>[];
    final errors = <ConfigLoaderError>[];
    if (config.suites.any(
      (s) => s.name == FlowRunImporter.kFlowSuiteName,
    )) {
      errors.add(
        ConfigLoaderError.generic(
          path: path,
          message:
              'A suite is named `${FlowRunImporter.kFlowSuiteName}`, which is '
              "the name of the project's flow entries. Rename the suite.",
        ),
      );
    }
    final seen = <String>{};
    const importer = FlowRunImporter();
    final root = p.dirname(config.projectFilePath);
    for (final entry in entries) {
      if (!seen.add(entry.name)) {
        errors.add(
          ConfigLoaderError.generic(
            path: path,
            message:
                'Flow entry `${entry.name}` is declared in more than one '
                'file. Entry names are test ids and must be unique.',
          ),
        );
      }
      final problem = importer.problemFor(importer.resolve(entry, root));
      if (problem != null) {
        errors.add(ConfigLoaderError.generic(path: path, message: problem));
      }
    }
    return errors;
  }

  /// [flow]'s entry paths and ingest paths made absolute against [baseDir],
  /// the directory of the file that declared them.
  static FlowConfig? _resolveFlowPaths(FlowConfig? flow, String baseDir) {
    if (flow == null) return null;
    const importer = FlowRunImporter();
    return FlowConfig(
      entries: <FlowEntry>[
        for (final entry in flow.entries) importer.resolve(entry, baseDir),
      ],
      ingest: <String>[
        for (final path in flow.ingest) p.normalize(p.join(baseDir, path)),
      ],
    );
  }

  /// [config] with its `flow:` entries resolved against the project
  /// directory and appended as the synthesised `flow` suite.
  RegressionConfig _withFlowSuite(RegressionConfig config) {
    final flow = config.flow;
    if (flow == null || flow.entries.isEmpty) return config;
    const importer = FlowRunImporter();
    final root = p.dirname(config.projectFilePath);
    final resolved = FlowConfig(
      entries: <FlowEntry>[
        for (final entry in flow.entries) importer.resolve(entry, root),
      ],
      ingest: flow.ingest,
    );
    return config.copyWith(
      suites: <Suite>[...config.suites, importer.suiteFor(resolved.entries)],
      flow: resolved,
    );
  }

  /// Recursive include-resolution body. [visited] holds the set of
  /// canonical absolute paths already loaded in this resolution to
  /// detect cycles. The inherited-defaults parameters are propagated
  /// from the parent file so an included file without its own
  /// `defaults.simulator` still produces well-formed `TestSpec`s.
  Future<RegressionConfig> _loadInternal(
    String absPath, {
    required Set<String> visited,
    String? inheritedSimulatorId,
    PassFailConfig? inheritedPassFail,
    WaveformPolicy? inheritedWaveform,
    Duration? inheritedTimeout,
    RiscvConfig? inheritedRiscv,
    FormalConfig? inheritedFormal,
  }) async {
    if (visited.contains(absPath)) {
      throw ConfigLoaderException([
        ConfigLoaderError.generic(
          path: absPath,
          message:
              'Cycle detected in `includes:` — `$absPath` was already loaded.',
        ),
      ]);
    }
    visited.add(absPath);

    final content = await _readFile(absPath);
    final root = parse(
      content,
      absPath,
      inheritedSimulatorId: inheritedSimulatorId,
      inheritedPassFail: inheritedPassFail,
      inheritedWaveform: inheritedWaveform,
      inheritedTimeout: inheritedTimeout,
      inheritedRiscv: inheritedRiscv,
      inheritedFormal: inheritedFormal,
    );
    final includes = _readIncludesList(content, absPath);

    final mergedSim = root.defaultSimulatorId ?? inheritedSimulatorId;
    final mergedPassFail = root.defaultPassFail ?? inheritedPassFail;
    final mergedWaveform = root.defaultWaveform ?? inheritedWaveform;
    // RegressionConfig does not keep the file's own `defaults.timeout`, so it
    // is read back here; without this an included file's tests fell back to
    // 300 s instead of the including file's timeout. Any error in the value
    // was already reported by `parse` above.
    final mergedTimeout =
        _ownDefaultTimeout(content, absPath) ?? inheritedTimeout;
    // Inheritance level 1 of 4: this file's flattened
    // `defaults.riscv` becomes the included files' inherited baseline.
    final mergedRiscv = root.defaultRiscv ?? inheritedRiscv;
    // The same first level for the general `formal:` block.
    final mergedFormal = root.defaultFormal ?? inheritedFormal;

    final includeConfigs = <RegressionConfig>[];
    for (final inc in includes) {
      final incAbs = p.normalize(p.join(p.dirname(absPath), inc));
      includeConfigs.add(
        await _loadInternal(
          incAbs,
          visited: visited,
          inheritedSimulatorId: mergedSim,
          inheritedPassFail: mergedPassFail,
          inheritedWaveform: mergedWaveform,
          inheritedTimeout: mergedTimeout,
          inheritedRiscv: mergedRiscv,
          inheritedFormal: mergedFormal,
        ),
      );
    }

    return _mergeConfigs(rootConfig: root, includeConfigs: includeConfigs);
  }

  /// The `defaults.timeout` written in [content] itself, or null when the
  /// file sets none (or sets one `parse` has already rejected).
  Duration? _ownDefaultTimeout(String content, String path) {
    final node = loadYamlNode(content, sourceUrl: Uri.file(path));
    if (node is! YamlMap) return null;
    return _readDuration(
      node,
      const ['defaults', 'timeout'],
      path,
      <ConfigLoaderError>[],
    );
  }

  /// Parses the `includes:` field from [content] (if present) into a
  /// list of relative paths. Validates that it is a YAML list of
  /// non-empty strings. Returns an empty list when the field is
  /// absent.
  List<String> _readIncludesList(String content, String path) {
    final node = loadYamlNode(content, sourceUrl: Uri.file(path));
    if (node is! YamlMap) return const <String>[];
    final inc = node.nodes['includes'];
    if (inc == null) return const <String>[];
    if (inc is! YamlList) {
      throw ConfigLoaderException([
        _error(
          path: path,
          node: inc,
          message: '`includes` must be a list of relative paths.',
        ),
      ]);
    }
    final out = <String>[];
    for (final entry in inc) {
      if (entry is! String || entry.isEmpty) {
        throw ConfigLoaderException([
          _error(
            path: path,
            node: inc,
            message:
                'Each entry in `includes` must be a non-empty string '
                '(relative path to another simcrux.yaml).',
          ),
        ]);
      }
      out.add(entry);
    }
    return out;
  }

  /// Reads the top-level `project_id:`, or null when the file has none.
  ///
  /// A value outside [kProjectIdPattern] is an error: a project id that
  /// differs from what `push-results --project` would accept would split a
  /// team's history between the app and its CI, which is the bug the key
  /// exists to end.
  String? _readProjectId(
    YamlMap root,
    String path,
    List<ConfigLoaderError> errors,
  ) {
    final node = root.nodes['project_id'];
    if (node == null) return null;
    final raw = node.value;
    final value = raw is String ? raw : raw?.toString();
    if (value != null && kProjectIdPattern.hasMatch(value)) return value;
    errors.add(
      _error(
        path: path,
        node: node,
        message:
            '`project_id` "${value ?? ''}" is not a valid project id. '
            '$kProjectIdRule',
      ),
    );
    return null;
  }

  /// The `project_id:` declared at the top of [yamlText], or null when the
  /// file declares none or declares one that does not pass
  /// [kProjectIdPattern].
  ///
  /// For readers that want the identity without loading the project: the
  /// shared team database resolves it from the active project's file, and
  /// a full load there would mean a second validation pass and a second
  /// place for the file's errors to surface. YAML that does not parse
  /// reads as "no id", which is what the team database should treat it as.
  static String? readProjectId(String yamlText) {
    try {
      final node = loadYamlNode(yamlText);
      if (node is! YamlMap) return null;
      final raw = node['project_id'];
      final value = raw is String ? raw : raw?.toString();
      if (value == null || !kProjectIdPattern.hasMatch(value)) return null;
      return value;
    } on Object {
      return null;
    }
  }

  /// Merges a root config with N include configs.
  ///
  /// - `suites:` are concatenated. Root-file suites win on
  ///   name conflicts (later wins in the appended list).
  /// - `simulatorBinaries:` are union-merged. Root wins.
  /// - `schemaVersion` / `defaultSimulatorId` / `defaultPassFail` /
  ///   `defaultWaveform` from the root file are retained.
  RegressionConfig _mergeConfigs({
    required RegressionConfig rootConfig,
    required List<RegressionConfig> includeConfigs,
  }) {
    if (includeConfigs.isEmpty) return rootConfig;

    final byName = <String, Suite>{};
    for (final inc in includeConfigs) {
      for (final s in inc.suites) {
        byName[s.name] = s;
      }
    }
    for (final s in rootConfig.suites) {
      byName[s.name] = s;
    }

    final sims = <String, SimulatorBinaryConfig>{};
    for (final inc in includeConfigs) {
      sims.addAll(inc.simulatorBinaries);
    }
    sims.addAll(rootConfig.simulatorBinaries);

    // Concatenate every included file's loadWarnings into the merged
    // config so a tier-gate warning emitted from inside an included
    // file surfaces alongside the root file's warnings on the
    // dashboard.
    final mergedWarnings = <ConfigLoaderError>[
      for (final inc in includeConfigs) ...inc.loadWarnings,
      ...rootConfig.loadWarnings,
    ];

    // `flow:` blocks concatenate, the root file's entries first; a name
    // declared twice is refused by [load] once every file is read.
    var mergedFlow = rootConfig.flow;
    for (final inc in includeConfigs) {
      final incFlow = inc.flow;
      if (incFlow == null) continue;
      mergedFlow = (mergedFlow ?? FlowConfig()).followedBy(incFlow);
    }

    return rootConfig.copyWith(
      suites: byName.values.toList(growable: false),
      simulatorBinaries: sims,
      flow: mergedFlow,
      loadWarnings: mergedWarnings,
    );
  }

  /// Expand every `.f` entry in every test's `sources` into its
  /// constituent source paths, merging the filelist's `+incdir+` and
  /// `+define+` directives into the test's `includeDirs` / `defines`.
  /// After filelist expansion, every relative source / include-dir
  /// path is normalized to an absolute path rooted at the project
  /// file's directory so the per-test working directory the
  /// scheduler allocates doesn't break source resolution.
  Future<RegressionConfig> _expandFilelistsInConfig(
    RegressionConfig config,
  ) async {
    final projectRoot = p.dirname(config.projectFilePath);
    final newSuites = <Suite>[];
    for (final suite in config.suites) {
      final newTests = <TestSpec>[];
      for (final test in suite.tests) {
        final expanded = await _expandTestFilelists(test, projectRoot);
        newTests.add(_resolveTestPaths(expanded, projectRoot));
      }
      newSuites.add(suite.copyWith(tests: newTests));
    }
    return config.copyWith(suites: newSuites);
  }

  /// Resolves every relative source / include-dir path on [test]
  /// against [projectRoot], leaving absolute paths untouched.
  TestSpec _resolveTestPaths(TestSpec test, String projectRoot) {
    String resolve(String pathArg) {
      if (p.isAbsolute(pathArg)) return p.normalize(pathArg);
      return p.normalize(p.join(projectRoot, pathArg));
    }

    // Re-key the per-source language map alongside the path
    // resolution so the mixed-language validator that runs *after*
    // path resolution can find each language by the now-absolute key.
    final resolvedLanguages = <String, HdlLanguage>{};
    for (final entry in test.sourceLanguages.entries) {
      resolvedLanguages[resolve(entry.key)] = entry.value;
    }

    return test.copyWith(
      sources: test.sources.map(resolve).toList(growable: false),
      includeDirs: test.includeDirs.map(resolve).toList(growable: false),
      sourceLanguages: resolvedLanguages,
      riscv: _resolveRiscvDemoCorpora(test.riscv, resolve),
      formal: _resolveFormalPaths(test.formal, resolve, projectRoot),
    );
  }

  /// Resolves the general `formal:` block's project paths (`sby_file`,
  /// `eqy_file`, `demo_outputs`) against the project file's directory and
  /// records that directory as the root property locations are reported
  /// against.
  ///
  /// `sby_binary`, `eqy_binary` and `tools` are install locations and stay
  /// verbatim, for the reason given on [_resolveRiscvDemoCorpora]; `command`
  /// and `extra_args` are placeholder-bearing and are expanded at spawn
  /// time.
  FormalConfig? _resolveFormalPaths(
    FormalConfig? formal,
    String Function(String) resolve,
    String projectRoot,
  ) {
    if (formal == null) return null;
    final sbyFile = formal.sbyFile;
    final eqyFile = formal.eqyFile;
    final demoOutputs = formal.demoOutputs;
    return formal.copyWith(
      sbyFile: sbyFile == null ? null : resolve(sbyFile),
      eqyFile: eqyFile == null ? null : resolve(eqyFile),
      demoOutputs: demoOutputs == null ? null : resolve(demoOutputs),
      projectRoot: p.normalize(projectRoot),
    );
  }

  /// Resolves the two RISC-V **demo-corpus roots** against the project
  /// file's directory, leaving absolute paths untouched.
  ///
  /// `riscv.demo_signatures` and `riscv.formal.demo_outputs` name
  /// directories that live in the user's project tree next to the
  /// `simcrux.yaml` that declares them — the committed corpora the drivers
  /// replay in `mode: demo`. Both drivers
  /// consume them as-is, so a relative value would otherwise resolve
  /// against the *process* working directory: fine for a `dart test` run
  /// launched from the repo root, useless for a GUI build, whose cwd is
  /// `/` when it is launched from Finder or a desktop launcher. Resolving
  /// them here is the same treatment `sources:` and `include_dirs:` already
  /// get, and it is what lets `examples/riscv-*-demo/simcrux.yaml` point at
  /// `../../verification/fixtures/…` and work from any checkout.
  ///
  /// Deliberately narrow. The rest of the `riscv:` block is left verbatim:
  ///
  /// * `reference.path`, `toolchain.path` and `formal.sby_binary` are
  ///   *install* locations, not project files — resolving them would change
  ///   engine detection, which is deliberately detect-and-guide (SimCrux
  ///   never bundles or installs an engine);
  /// * `compile.link_script`, `compile.include_dirs` and every `command:`
  ///   element are placeholder-bearing (`{elf}`, `{work_dir}`, …) and are
  ///   expanded at spawn time, so pre-resolving them would corrupt a
  ///   placeholder into a path;
  /// * `arch_test.suite_path` and `formal.checks_dir` are consumed on the
  ///   spawn path only, where the drivers already resolve against their own
  ///   roots.
  RiscvConfig? _resolveRiscvDemoCorpora(
    RiscvConfig? riscv,
    String Function(String) resolve,
  ) {
    if (riscv == null) return null;
    final demoSignatures = riscv.demoSignatures;
    final formal = riscv.formal;
    final demoOutputs = formal?.demoOutputs;
    if (demoSignatures == null && demoOutputs == null) return riscv;
    return riscv.copyWith(
      demoSignatures: demoSignatures == null ? null : resolve(demoSignatures),
      formal: demoOutputs == null
          ? null
          : formal!.copyWith(demoOutputs: resolve(demoOutputs)),
    );
  }

  Future<TestSpec> _expandTestFilelists(
    TestSpec test,
    String projectRoot,
  ) async {
    final filelistPaths = <String>[];
    final passthrough = <String>[];
    for (final src in test.sources) {
      if (src.toLowerCase().endsWith('.f')) {
        filelistPaths.add(src);
      } else {
        passthrough.add(src);
      }
    }
    if (filelistPaths.isEmpty) return test;

    final mergedSources = <String>[...passthrough];
    final mergedIncludeDirs = <String>[...test.includeDirs];
    final mergedDefines = <String, String>{...test.defines};

    for (final relPath in filelistPaths) {
      final abs = p.isAbsolute(relPath)
          ? p.normalize(relPath)
          : p.normalize(p.join(projectRoot, relPath));
      final exp = await _filelistExpander.expand(
        filelistPath: abs,
        projectRoot: projectRoot,
      );
      mergedSources.addAll(exp.sources);
      mergedIncludeDirs.addAll(exp.includeDirs);
      mergedDefines.addAll(exp.defines);
    }

    return test.copyWith(
      sources: mergedSources,
      includeDirs: mergedIncludeDirs,
      defines: mergedDefines,
    );
  }

  /// Synchronous core. Exposed so tests can drive the loader off a
  /// literal YAML string.
  ///
  /// [inheritedSimulatorId] / [inheritedPassFail] / [inheritedWaveform] /
  /// [inheritedTimeout] are propagated by [_loadInternal] when this
  /// file was reached through a parent's `includes:` directive — they
  /// fill in fallbacks for the included file's own `defaults:` block,
  /// so an include without its own `defaults.simulator` inherits the
  /// root file's. Direct callers (tests, single-file parses) leave
  /// these null.
  RegressionConfig parse(
    String yamlContent,
    String path, {
    String? inheritedSimulatorId,
    PassFailConfig? inheritedPassFail,
    WaveformPolicy? inheritedWaveform,
    Duration? inheritedTimeout,
    RiscvConfig? inheritedRiscv,
    FormalConfig? inheritedFormal,
  }) {
    final errors = <ConfigLoaderError>[];

    final YamlNode rootNode;
    try {
      rootNode = loadYamlNode(yamlContent, sourceUrl: Uri.file(path));
    } on YamlException catch (e) {
      throw ConfigLoaderException([
        ConfigLoaderError(
          path: path,
          message: 'YAML parse error: ${e.message}',
          line: e.span?.start.line != null ? e.span!.start.line + 1 : null,
          column: e.span?.start.column != null
              ? e.span!.start.column + 1
              : null,
        ),
      ]);
    }

    if (rootNode is! YamlMap) {
      throw ConfigLoaderException([
        _error(
          path: path,
          node: rootNode,
          message: 'Project file root must be a YAML map.',
        ),
      ]);
    }

    final root = rootNode;

    // ── version ─────────────────────────────────────────────────────
    final version = _requireString(root, 'version', path, errors);
    if (version != null && version != supportedSchemaVersion) {
      errors.add(
        _error(
          path: path,
          node: root.nodes['version'],
          message:
              'Unsupported schema version "$version". Expected "$supportedSchemaVersion".',
        ),
      );
    }

    // ── project_id ──────────────────────────────────────────────────
    final projectId = _readProjectId(root, path, errors);

    // ── defaults ────────────────────────────────────────────────────
    final defaultsRaw = root['defaults'];
    final defaultSimulatorId =
        _readString(root, ['defaults', 'simulator']) ?? inheritedSimulatorId;
    final defaultPassFail =
        _readPassFailConfig(
          root,
          ['defaults', 'pass_fail'],
          path,
          errors,
          reusableDetectors: _reusableDetectors,
        ) ??
        inheritedPassFail;
    final defaultWaveform =
        _readWaveformPolicy(root, ['defaults', 'waveform'], path, errors) ??
        inheritedWaveform;
    final defaultTimeoutValue =
        _readDuration(root, ['defaults', 'timeout'], path, errors) ??
        inheritedTimeout ??
        defaultTimeout;
    // Inheritance level 2 of 4: the project file's own `defaults.riscv`,
    // merged field-by-field over whatever an including file supplied.
    // `mergeOnto` rather than `??` so a `defaults:` block that sets only
    // `signature.word_size` does not discard the parent's `target.command`.
    final defaultRiscv =
        _readRiscvConfig(
          root,
          ['defaults', 'riscv'],
          path,
          errors,
          allowTooling: _allowProjectDefinedTooling,
        )?.mergeOnto(inheritedRiscv) ??
        inheritedRiscv;
    // Level 2 of 4 for the general `formal:` block.
    final defaultFormal =
        _readFormalConfig(
          root,
          ['defaults', 'formal'],
          path,
          errors,
          allowTooling: _allowProjectDefinedTooling,
        )?.mergeOnto(inheritedFormal) ??
        inheritedFormal;

    if (defaultsRaw != null && defaultsRaw is! YamlMap) {
      errors.add(
        _error(
          path: path,
          node: root.nodes['defaults'],
          message: '`defaults` must be a map.',
        ),
      );
    }

    // ── simulators (optional) ───────────────────────────────────────
    final simulatorBinaries = _readSimulatorBinaries(
      root,
      path,
      errors,
      allowTooling: _allowProjectDefinedTooling,
    );

    // ── output (optional) ──────────────────────────────────────────
    final output = _readOutputConfig(
      root,
      path,
      errors,
      allowTooling: _allowProjectDefinedTooling,
    );

    // ── flow (optional) ─────────────────────────────────────────────
    // Paths resolve against the file that wrote them, so an included
    // file's entries mean what they meant in that file.
    final flow = _resolveFlowPaths(
      _readFlowConfig(
        root,
        path,
        errors,
        allowTooling: _allowProjectDefinedTooling,
      ),
      p.dirname(p.absolute(path)),
    );

    // ── suites ──────────────────────────────────────────────────────
    final suitesNode = root.nodes['suites'];
    final suites = <Suite>[];
    if (suitesNode == null) {
      // Absence is allowed — included files often carry only defaults
      // or simulators; the merged top-level config is validated by
      // [load] for at-least-one-suite.
    } else if (suitesNode is! YamlMap) {
      errors.add(
        _error(
          path: path,
          node: suitesNode,
          message: '`suites` must be a map of suite name to suite config.',
        ),
      );
    } else if (suitesNode.isEmpty) {
      // Same as null — empty map is permissible.
    } else {
      for (final entry in suitesNode.nodes.entries) {
        final keyNode = entry.key as YamlNode;
        final valueNode = entry.value;
        final suiteName = (keyNode.value ?? '').toString();
        if (suiteName.isEmpty) {
          errors.add(
            _error(
              path: path,
              node: keyNode,
              message: 'Suite name must be a non-empty string.',
            ),
          );
          continue;
        }
        if (valueNode is! YamlMap) {
          errors.add(
            _error(
              path: path,
              node: valueNode,
              message: 'Suite `$suiteName` must be a map.',
            ),
          );
          continue;
        }
        final suite = _parseSuite(
          suiteName: suiteName,
          suiteNode: valueNode,
          path: path,
          errors: errors,
          inheritedSimulatorId: defaultSimulatorId,
          inheritedPassFail: defaultPassFail,
          inheritedWaveform: defaultWaveform,
          inheritedTimeout: defaultTimeoutValue,
          inheritedRiscv: defaultRiscv,
          inheritedFormal: defaultFormal,
        );
        if (suite != null) suites.add(suite);
      }
    }

    final fatal = errors.where((e) => e.isFatal).toList(growable: false);
    // Every non-fatal entry, `warning` and `info` alike: the dashboard
    // decides which of them a switch may hide, by severity.
    final warnings = errors.where((e) => !e.isFatal).toList(growable: false);
    if (fatal.isNotEmpty) throw ConfigLoaderException(fatal);

    return RegressionConfig(
      projectFilePath: path,
      schemaVersion: supportedSchemaVersion,
      suites: suites,
      simulatorBinaries: simulatorBinaries,
      defaultSimulatorId: defaultSimulatorId,
      projectId: projectId,
      defaultPassFail: defaultPassFail,
      defaultWaveform: defaultWaveform,
      defaultRiscv: defaultRiscv,
      defaultFormal: defaultFormal,
      output: output,
      flow: flow,
      loadWarnings: warnings,
    );
  }

  Suite? _parseSuite({
    required String suiteName,
    required YamlMap suiteNode,
    required String path,
    required List<ConfigLoaderError> errors,
    required String? inheritedSimulatorId,
    required PassFailConfig? inheritedPassFail,
    required WaveformPolicy? inheritedWaveform,
    required Duration inheritedTimeout,
    required RiscvConfig? inheritedRiscv,
    required FormalConfig? inheritedFormal,
  }) {
    final description = _readString(suiteNode, ['description']);
    final suiteSimulatorId =
        _readString(suiteNode, ['simulator']) ?? inheritedSimulatorId;
    final suitePassFail =
        _readPassFailConfig(
          suiteNode,
          ['pass_fail'],
          path,
          errors,
          reusableDetectors: _reusableDetectors,
        ) ??
        inheritedPassFail;
    final suiteWaveform =
        _readWaveformPolicy(suiteNode, ['waveform'], path, errors) ??
        inheritedWaveform;
    final suiteTimeout =
        _readDuration(suiteNode, ['timeout'], path, errors) ?? inheritedTimeout;
    // Inheritance level 3 of 4: the suite's own `riscv:`.
    final suiteRiscv =
        _readRiscvConfig(
          suiteNode,
          ['riscv'],
          path,
          errors,
          allowTooling: _allowProjectDefinedTooling,
        )?.mergeOnto(inheritedRiscv) ??
        inheritedRiscv;
    // Level 3 of 4 for the general `formal:` block.
    final suiteFormal =
        _readFormalConfig(
          suiteNode,
          ['formal'],
          path,
          errors,
          allowTooling: _allowProjectDefinedTooling,
        )?.mergeOnto(inheritedFormal) ??
        inheritedFormal;
    final suiteSourcesParsed = _readSourceEntries(
      suiteNode,
      ['sources'],
      path,
      errors,
    );
    final suiteSources = suiteSourcesParsed?.paths;
    final suiteSourceLanguages = suiteSourcesParsed?.languages;
    final suiteIncludeDirs = _readStringList(suiteNode, ['include_dirs']);
    final suiteDefines = _readStringMap(suiteNode, ['defines'], path, errors);
    final suiteResources = _readResourceLocks(
      suiteNode,
      ['resources'],
      path,
      errors,
    );

    final testsNode = suiteNode.nodes['tests'];
    if (testsNode == null) {
      errors.add(
        _error(
          path: path,
          node: suiteNode,
          message: 'Suite `$suiteName` must declare a `tests` list.',
        ),
      );
      return null;
    }
    if (testsNode is! YamlList) {
      errors.add(
        _error(
          path: path,
          node: testsNode,
          message: '`tests` for suite `$suiteName` must be a list.',
        ),
      );
      return null;
    }

    final tests = <TestSpec>[];
    for (final entry in testsNode.nodes) {
      final testNode = entry;
      if (testNode is! YamlMap) {
        errors.add(
          _error(
            path: path,
            node: testNode,
            message:
                'Each test in suite `$suiteName` must be a map (name + top + ...).',
          ),
        );
        continue;
      }
      final testName = _requireString(testNode, 'name', path, errors);
      final top = _requireString(testNode, 'top', path, errors);
      if (testName == null || top == null) continue;

      final testSimulatorId =
          _readString(testNode, ['simulator']) ??
          suiteSimulatorId ??
          simulatorPolicy.fallbackSimulatorId;
      if (testSimulatorId == null) {
        errors.add(
          _error(
            path: path,
            node: testNode,
            message:
                "Test `$suiteName/$testName` has no simulator (set `defaults.simulator`, the suite's `simulator:`, or the test's `simulator:`).",
          ),
        );
        continue;
      }
      final allowedSimulators = simulatorPolicy.allowedSimulatorIds;
      if (allowedSimulators != null &&
          !allowedSimulators.contains(testSimulatorId)) {
        // Fatal, not an advisory that drops the test: a dropped test is a
        // run that reports green on fewer tests than the project declares,
        // which under `--ci` is the silent-false-clean failure.
        errors.add(
          _error(
            path: path,
            node: testNode,
            message: simulatorNotAllowedMessage(
              testId: '$suiteName/$testName',
              simulatorId: testSimulatorId,
              allowed: allowedSimulators,
            ),
          ),
        );
        continue;
      }

      final testPassFail =
          _readPassFailConfig(
            testNode,
            ['pass_fail'],
            path,
            errors,
            reusableDetectors: _reusableDetectors,
          ) ??
          suitePassFail ??
          const ExitCodePassFailConfig();
      final testWaveform =
          _readWaveformPolicy(testNode, ['waveform'], path, errors) ??
          suiteWaveform ??
          const WaveformPolicy();
      final testTimeout =
          _readDuration(testNode, ['timeout'], path, errors) ?? suiteTimeout;
      // Inheritance level 4 of 4: the test's own `riscv:`. Completeness is
      // then validated on the *flattened* result, because a project may
      // legitimately declare the shared plumbing once in `defaults:` and
      // only the per-test `test:` / `extension:` here.
      final testRiscv =
          _readRiscvConfig(
            testNode,
            ['riscv'],
            path,
            errors,
            allowTooling: _allowProjectDefinedTooling,
          )?.mergeOnto(suiteRiscv) ??
          suiteRiscv;
      _validateRiscvForTest(
        riscv: testRiscv,
        simulatorId: testSimulatorId,
        suiteName: suiteName,
        testName: testName,
        filePath: path,
        testNode: testNode,
        errors: errors,
      );
      // Level 4 of 4 for the general `formal:` block, validated on the
      // flattened result like `riscv:`.
      final testFormal =
          _readFormalConfig(
            testNode,
            ['formal'],
            path,
            errors,
            allowTooling: _allowProjectDefinedTooling,
          )?.mergeOnto(suiteFormal) ??
          suiteFormal;
      _validateFormalForTest(
        formal: testFormal,
        simulatorId: testSimulatorId,
        suiteName: suiteName,
        testName: testName,
        filePath: path,
        testNode: testNode,
        errors: errors,
      );

      final testSourcesParsed = _readSourceEntries(
        testNode,
        ['sources'],
        path,
        errors,
      );
      final testSources = testSourcesParsed?.paths ?? const <String>[];
      final testSourceLanguages =
          testSourcesParsed?.languages ?? const <String, HdlLanguage>{};
      final mergedSources = [...?suiteSources, ...testSources];
      final mergedSourceLanguages = <String, HdlLanguage>{
        ...?suiteSourceLanguages,
        ...testSourceLanguages,
      };
      final testIncludeDirs =
          _readStringList(testNode, ['include_dirs']) ?? const [];
      final mergedIncludeDirs = [...?suiteIncludeDirs, ...testIncludeDirs];
      final testDefines =
          _readStringMap(testNode, ['defines'], path, errors) ??
          <String, String>{};
      final mergedDefines = <String, String>{
        ...?suiteDefines,
        ...testDefines,
      };
      // The `parameters:` block accepts two shapes:
      //   1. Scalar single-bound values: `parameters: { MEM_SIZE: "1024" }`
      //   2. Sweep-form lists: `parameters: { MEM_SIZE: ["1024", "4096"] }`
      // [_readSweepableParameters] returns the bound (scalar) values
      // and the sweep axes as two separate maps so the caller can
      // route them into the right TestSpec field.
      final paramShape = _readSweepableParameters(
        testNode,
        ['parameters'],
        path,
        errors,
      );
      final testBoundParameters = paramShape.bound;
      final rawParameterSweeps = paramShape.sweeps;
      // cocotb hands `top` and every parameter to `make` as `KEY=value`, so
      // a `$(shell …)` in any of them runs on the machine that opens the
      // file. Refused unless a human trusts the file; `top` cannot be
      // dropped the way an option can, so the test is refused as a whole.
      if (testSimulatorId == 'cocotb' && !_allowProjectDefinedTooling) {
        final makeBound = <String, String>{
          'top': top,
          for (final e in testBoundParameters.entries)
            'parameters.${e.key}': e.value,
          for (final e in rawParameterSweeps.entries)
            for (final v in e.value) 'parameters.${e.key}': v,
        };
        var refused = false;
        for (final e in makeBound.entries) {
          final problem = _toolingExpansionProblem(e.value);
          if (problem == null) continue;
          refused = true;
          errors.add(
            _error(
              path: path,
              node: e.key == 'top'
                  ? testNode.nodes['top']
                  : (testNode.nodes['parameters'] as YamlMap?)?.nodes[e.key
                            .substring('parameters.'.length)] ??
                        testNode,
              message:
                  'Test `$suiteName/$testName`: `${e.key}` becomes a make '
                  'variable for cocotb, and its value $problem. '
                  '$kProjectToolingRemedy',
            ),
          );
        }
        if (refused) continue;
      }
      if (testSimulatorId == 'cocotb') {
        for (final value in <String?>[
          testBoundParameters['max_failures'],
          ...?rawParameterSweeps['max_failures'],
        ]) {
          if (_isCocotbMaxFailures(value)) continue;
          errors.add(
            _error(
              path: path,
              node:
                  (testNode.nodes['parameters'] as YamlMap?)
                      ?.nodes['max_failures'] ??
                  testNode,
              message: _cocotbMaxFailuresMessage(
                'parameters.max_failures',
                value!,
              ),
            ),
          );
          break;
        }
      }
      final rawSeeds = _readSeedsField(testNode, ['seeds'], path, errors);
      final scalarSeed = _readScalarSeedField(testNode, ['seed'], path, errors);
      final testResources =
          _readResourceLocks(testNode, ['resources'], path, errors) ??
          const <ResourceLock>[];
      final mergedResources = [...?suiteResources, ...testResources];

      // Gate the sweep blocks behind the active license tier. Open
      // Core (post-beta) silently drops the sweep declaration and
      // records a single advisory warning per offending field so the
      // user understands why their multi-value sweep ran exactly once.
      //
      // The gated path is "drop and log" rather than "error and
      // refuse" because the test definition itself is otherwise valid
      // — the unparameterized run is still useful. Pro / EDU /
      // Enterprise users (and every user during the beta period) reach
      // the [TestSpecExpander] below with both sweeps intact.
      // Explicit nullable types so the `effectiveSeeds = null`
      // assignment below (when the tier-gate drops the sweep) is
      // legal — `rawSeeds` is `List<int>?` and infers to non-nullable
      // when used as an initializer.
      // ignore: omit_local_variable_types
      List<int>? effectiveSeeds = rawSeeds;
      Map<String, List<String>>? effectiveSweeps = rawParameterSweeps;
      // `info`, not `warning`: this is the one advisory the Pro overlay's
      // Parameterization switch may hide. The tooling gate's advisories
      // stay `warning` so that switch cannot silence them.
      if (!_parameterizationUnlocked) {
        if (rawSeeds != null && rawSeeds.length > 1) {
          errors.add(
            _error(
              path: path,
              node: testNode.nodes['seeds'],
              message: parameterizationGateMessage('seeds'),
              severity: ConfigLoaderErrorSeverity.info,
            ),
          );
          effectiveSeeds = null;
        }
        if (rawParameterSweeps.isNotEmpty) {
          errors.add(
            _error(
              path: path,
              node: testNode.nodes['parameters'],
              message: parameterizationGateMessage('parameters'),
              severity: ConfigLoaderErrorSeverity.info,
            ),
          );
          effectiveSweeps = null;
        }
      }

      // A `seeds:` block with exactly one element is treated as the
      // scalar `seed:` form by the loader: no expansion, the single
      // value is pinned directly. This keeps trivial sweeps cheap and
      // avoids creating phantom "+seed=N" suffixes on the test id.
      final effectiveScalarSeed =
          scalarSeed ??
          (effectiveSeeds != null && effectiveSeeds.length == 1
              ? effectiveSeeds.first
              : null);
      final effectiveSeedsForTemplate =
          (effectiveSeeds != null && effectiveSeeds.length > 1)
          ? effectiveSeeds
          : null;
      final effectiveSweepsForTemplate =
          (effectiveSweeps == null || effectiveSweeps.isEmpty)
          ? null
          : effectiveSweeps;

      final template = TestSpec(
        id: _buildTestId(suiteName, testName, testBoundParameters),
        name: testName,
        suiteName: suiteName,
        simulatorId: testSimulatorId,
        top: top,
        sources: mergedSources,
        includeDirs: mergedIncludeDirs,
        defines: mergedDefines,
        parameters: testBoundParameters,
        passFail: testPassFail,
        waveform: testWaveform,
        resources: mergedResources,
        timeout: testTimeout,
        sourceLanguages: mergedSourceLanguages,
        seed: effectiveScalarSeed,
        seeds: effectiveSeedsForTemplate,
        parameterSweeps: effectiveSweepsForTemplate,
        // Set on the *template*, so every child the expander materializes
        // below inherits it through `TestSpec.copyWith`.
        riscv: testRiscv,
        formal: testFormal,
      );

      if (!template.isParameterized) {
        tests.add(template);
        continue;
      }

      // Runaway-protection: reject parameterized templates whose
      // cartesian product would exceed [_maxExpansionSize] (default
      // 10 000). The error message mentions the actual size so the
      // user can decide whether to trim or raise the limit.
      //
      // The ceiling is not a command-line flag. The only control that
      // raises it is the Pro overlay's Settings rail entry, for desktop
      // project loads; `--ci` and `bin/simcrux.dart` construct the loader
      // with the default. The message says so, because a CI log is where
      // this error is most often read and no setting reaches that run.
      // The setting's path is quoted as the rail labels it.
      final size = expander.expansionSize(template);
      if (size <= 0 || size > _maxExpansionSize) {
        errors.add(
          _error(
            path: path,
            node: testNode,
            message:
                'Test `$suiteName/$testName` would expand into $size '
                'concrete specs (max $_maxExpansionSize). Reduce the seed '
                'sweep / parameter sweep, or raise the ceiling in SimCrux '
                'Pro at Settings → Test Execution — Parameterization → '
                'Max expansion size (desktop project loads only; `--ci` '
                'always uses the default).',
          ),
        );
        continue;
      }
      tests.addAll(expander.expand(template));
    }

    return Suite(name: suiteName, description: description, tests: tests);
  }

  String _buildTestId(
    String suite,
    String test,
    Map<String, String> parameters,
  ) {
    if (parameters.isEmpty) return '$suite/$test';
    final sorted = parameters.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final suffix = sorted.map((e) => '${e.key}=${e.value}').join('+');
    return '$suite/$test+$suffix';
  }
}
