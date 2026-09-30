// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

part of 'config_loader.dart';

// ── the `riscv:` block ────────────────────────────────────────────────
//
// Its own part file rather than more lines
// in `config_loader.dart`, alongside the other section readers.
//
// ## No tier gate — deliberately, and forever
//
// This library already contains a tier gate: `_parameterizationUnlocked`,
// which returns true during `kBetaPeriod` and consults
// `LicenseTier.featureEquivalent` afterwards to gate `seeds:` /
// `parameters:` sweep expansion. **Nothing below has an analogue, and
// nothing below may ever acquire one** — including after `kBetaPeriod`
// flips to `false`.
//
// The asymmetry is the point, and it is recorded here (as it is next to
// `_readGoldenCompareConfig`, for the same reason) so that a
// later consistency pass noticing "one config block is gated and another is
// not" does not "fix" it. Sweeps are a *productivity* feature and are Pro.
// A compatibility verdict is *correctness* and is free: compatibility is
// RVI's own program, and monetizing the verdict itself would be read as
// tolling a standard. The rule covers the whole `riscv:` path, not only the
// `golden_compare` detector's reader.
//
// ## Four inheritance levels, not three
//
// The `riscv:` block is read at four sites, each merging over the one
// above via `RiscvConfig.mergeOnto`:
//
//   1. an included file's own `defaults.riscv` (threaded in as
//      `inheritedRiscv` by `_loadInternal`)
//   2. the project file's `defaults.riscv`
//   3. `suites.<name>.riscv`
//   4. the test's `riscv:`
//
// Missing any one of them makes a per-test `riscv:` silently ignore that
// level, which is exactly the class of bug that is invisible until someone
// wonders why their suite-level `word_size` did not apply.
//
// ## Errors accumulate
//
// Every reader below appends to `errors` and returns what it could parse,
// rather than throwing on the first problem, so one load shows the whole
// punch list with `file:line:col` spans. The messages are unlocalized
// English literals: config-loader diagnostics have no localization channel
// at all, and inventing one is far larger than the RISC-V path warrants.
//
// ## `MixedLanguageValidator`, `riscv_arch` and `riscv_formal`
//
// Both ids are deliberately **absent** from
// `ConfigLoader.defaultSimulatorLanguages`, so the validator's
// "skip tests whose simulator id isn't in the catalog" branch is what
// applies. That catalog maps a simulator id to the set of **HDL languages
// it can compile**, and neither driver compiles HDL from `sources:`:
// `riscv_arch` cross-compiles RISC-V assembly, and `riscv_formal` hands a
// `.sby` file to SymbiYosys, which declares its own sources in the job
// file's `[files]` / `[script]` sections. Registering either with an empty
// set would make every source an error, and registering them with the HDL
// union would be a lie about what the drivers do. The skip is the correct
// behavior and is already the validator's documented contract.
//
// ## Two drivers, one block
//
// `riscv.formal:` sits alongside the compatibility keys rather than in a second
// top-level block. `isa`, `mode` and `demo_case` are genuinely shared, and
// a project that runs both the compatibility suite and the formal check
// set declares them once. Completeness validation is scoped by
// `simulatorId`, so a sub-block the other driver owns is inert, never an
// error.

RiscvConfig? _readRiscvConfig(
  YamlMap map,
  List<String> path,
  String filePath,
  List<ConfigLoaderError> errors, {
  required bool allowTooling,
}) {
  Object? node = map;
  YamlNode? currentNode = map;
  for (final key in path) {
    if (node is! YamlMap) return null;
    currentNode = node.nodes[key];
    node = node[key];
  }
  if (node == null) return null;
  final label = path.isEmpty ? 'riscv' : path.join('.');
  if (node is! YamlMap) {
    errors.add(
      _error(
        path: filePath,
        node: currentNode,
        message: '`$label` must be a map.',
      ),
    );
    return null;
  }

  final mode = _readRiscvMode(node, label, filePath, errors);
  if (!allowTooling) {
    // The `command:` argv lists come straight out of the project file:
    // both RISC-V drivers spawn `argv.first` with `argv.skip(1)` as its
    // arguments (`riscv_arch_driver.dart` for target / riscof / compile,
    // `riscv_formal_driver.dart`'s `buildArgv` for formal). That is the
    // most direct code-execution key in the schema — more direct than
    // `simulators.<id>.path`, which at least has to name a binary the
    // driver already knows how to call. Refuse the load outright rather
    // than dropping the command: a command is the whole invocation, and
    // running a different one than the file asked for (or none, and a
    // second "`target.command` is required" error) is worse than one
    // clear diagnostic.
    for (final key in _kRiscvCommandBlocks) {
      final sub = node[key];
      if (sub is! YamlMap) continue;
      final command = sub['command'];
      if (command == null) continue;
      errors.add(
        _error(
          path: filePath,
          node: (node.nodes[key] as YamlMap?)?.nodes['command'],
          message:
              '`$label.$key.command` names an executable for SimCrux to '
              'spawn, which a project file may not do on its own. '
              '$kProjectToolingRemedy',
        ),
      );
    }
  }
  final gate = _RiscvExecutableGate(allowTooling: allowTooling);
  final config = RiscvConfig(
    isa: _readRiscvString(node, 'isa', label, filePath, errors),
    reference: _readRiscvReference(node, label, filePath, errors, gate),
    archTest: _readRiscvArchTest(node, label, filePath, errors),
    toolchain: _readRiscvToolchain(node, label, filePath, errors, gate),
    target: _readRiscvTarget(node, label, filePath, errors),
    compile: _readRiscvCompile(node, label, filePath, errors),
    riscof: _readRiscvRiscof(node, label, filePath, errors, gate),
    signature: _readRiscvSignature(node, label, filePath, errors),
    formal: _readRiscvFormal(node, label, filePath, errors, gate),
    extensions: _readRiscvStringList(
      node,
      'extensions',
      label,
      filePath,
      errors,
    ),
    mode: mode,
    demoSignatures: _readRiscvString(
      node,
      'demo_signatures',
      label,
      filePath,
      errors,
    ),
    testPath: _readRiscvString(node, 'test', label, filePath, errors),
    extension: _readRiscvString(node, 'extension', label, filePath, errors),
    demoCase: _readRiscvString(node, 'demo_case', label, filePath, errors),
  );
  if (gate.dropped.isNotEmpty) {
    final keys = gate.dropped.map((d) => '`${d.key}`').join(', ');
    errors.add(
      _error(
        path: filePath,
        node: gate.dropped.first.node,
        severity: ConfigLoaderErrorSeverity.warning,
        message:
            'Ignored $keys: a project file may not choose which program '
            'SimCrux runs. The conventional executable names are looked up '
            'on PATH instead. $kProjectToolingRemedy',
      ),
    );
  }
  return config;
}

/// The `riscv:` sub-blocks whose `command:` is an argv list a driver
/// spawns verbatim. A project file that sets one is refused unless
/// project-defined tooling is allowed.
const List<String> _kRiscvCommandBlocks = <String>[
  'target',
  'riscof',
  'compile',
  'formal',
];

/// The project-tooling gate over the `riscv:` block's **executable-naming
/// scalars** — the keys that decide argv[0] without being a whole command:
///
/// - `reference.path` — the reference model `riscv_arch` spawns
///   (`RiscvToolchainProbe.referenceModelBinary`);
/// - `toolchain.path` and `toolchain.prefix` — together the cross-compiler
///   `riscv_arch` spawns (`<path>/<prefix>gcc`; a prefix alone can be an
///   absolute path);
/// - `riscof.binary` — the RISCOF executable;
/// - `formal.sby_binary` — the SymbiYosys executable `riscv_formal` spawns
///   when no `formal.command` is set.
///
/// With the gate closed each is dropped, like `simulators.<id>.path`, and
/// the driver falls back to the conventional name on PATH; one load
/// advisory per `riscv:` block names every key dropped. Dropped rather than
/// refused because, unlike a `command:`, each has a safe default that does
/// the same job with the user's own install.
class _RiscvExecutableGate {
  _RiscvExecutableGate({required this.allowTooling});

  final bool allowTooling;

  /// Every key dropped so far, as a dotted label and its YAML node.
  final List<({String key, YamlNode? node})> dropped =
      <({String key, YamlNode? node})>[];

  /// Reads the string [key] of [node] like `_readRiscvString`, then drops
  /// it (returning null) when the gate is closed.
  String? read(
    YamlMap node,
    String key,
    String label,
    String filePath,
    List<ConfigLoaderError> errors,
  ) {
    final value = _readRiscvString(node, key, label, filePath, errors);
    if (value == null || allowTooling) return value;
    dropped.add((key: '$label.$key', node: node.nodes[key]));
    return null;
  }
}

RiscvRunMode? _readRiscvMode(
  YamlMap node,
  String label,
  String filePath,
  List<ConfigLoaderError> errors,
) {
  final raw = node['mode'];
  if (raw == null) return null;
  final parsed = RiscvRunMode.fromWireName(raw);
  if (parsed != null) return parsed;
  errors.add(
    _error(
      path: filePath,
      node: node.nodes['mode'],
      message:
          '`$label.mode` must be one of ${RiscvRunMode.wireNames.join(', ')} '
          '(got "$raw"). Note `riscof_passthrough` is a documented secondary '
          'path: SimCrux still schedules one job per test, so the configured '
          'command is spawned once per test and per-test progress applies to '
          "the invocation, not to RISCOF's internal test loop.",
    ),
  );
  return null;
}

RiscvReferenceConfig? _readRiscvReference(
  YamlMap parent,
  String label,
  String filePath,
  List<ConfigLoaderError> errors,
  _RiscvExecutableGate gate,
) {
  final node = _riscvSubMap(parent, 'reference', label, filePath, errors);
  if (node == null) return null;
  RiscvReferenceModel? model;
  final rawModel = node['model'];
  if (rawModel != null) {
    model = RiscvReferenceModel.fromWireName(rawModel);
    if (model == null) {
      errors.add(
        _error(
          path: filePath,
          node: node.nodes['model'],
          message:
              '`$label.reference.model` must be one of '
              '${RiscvReferenceModel.wireNames.join(', ')} (got "$rawModel").',
        ),
      );
    }
  }
  return RiscvReferenceConfig(
    model: model,
    path: gate.read(node, 'path', '$label.reference', filePath, errors),
    args: _readRiscvStringList(
      node,
      'args',
      '$label.reference',
      filePath,
      errors,
    ),
  );
}

RiscvArchTestConfig? _readRiscvArchTest(
  YamlMap parent,
  String label,
  String filePath,
  List<ConfigLoaderError> errors,
) {
  final node = _riscvSubMap(parent, 'arch_test', label, filePath, errors);
  if (node == null) return null;
  return RiscvArchTestConfig(
    suitePath: _readRiscvString(
      node,
      'suite_path',
      '$label.arch_test',
      filePath,
      errors,
    ),
    revision: _readRiscvString(
      node,
      'revision',
      '$label.arch_test',
      filePath,
      errors,
    ),
  );
}

RiscvToolchainConfig? _readRiscvToolchain(
  YamlMap parent,
  String label,
  String filePath,
  List<ConfigLoaderError> errors,
  _RiscvExecutableGate gate,
) {
  final node = _riscvSubMap(parent, 'toolchain', label, filePath, errors);
  if (node == null) return null;
  return RiscvToolchainConfig(
    prefix: gate.read(node, 'prefix', '$label.toolchain', filePath, errors),
    path: gate.read(node, 'path', '$label.toolchain', filePath, errors),
  );
}

RiscvTargetConfig? _readRiscvTarget(
  YamlMap parent,
  String label,
  String filePath,
  List<ConfigLoaderError> errors,
) {
  final node = _riscvSubMap(parent, 'target', label, filePath, errors);
  if (node == null) return null;
  return RiscvTargetConfig(
    command: _readRiscvStringList(
      node,
      'command',
      '$label.target',
      filePath,
      errors,
    ),
    pluginPath: _readRiscvString(
      node,
      'plugin_path',
      '$label.target',
      filePath,
      errors,
    ),
  );
}

RiscvCompileConfig? _readRiscvCompile(
  YamlMap parent,
  String label,
  String filePath,
  List<ConfigLoaderError> errors,
) {
  final node = _riscvSubMap(parent, 'compile', label, filePath, errors);
  if (node == null) return null;
  return RiscvCompileConfig(
    command: _readRiscvStringList(
      node,
      'command',
      '$label.compile',
      filePath,
      errors,
    ),
    extraArgs: _readRiscvStringList(
      node,
      'extra_args',
      '$label.compile',
      filePath,
      errors,
    ),
    linkScript: _readRiscvString(
      node,
      'link_script',
      '$label.compile',
      filePath,
      errors,
    ),
    includeDirs: _readRiscvStringList(
      node,
      'include_dirs',
      '$label.compile',
      filePath,
      errors,
    ),
  );
}

RiscvRiscofConfig? _readRiscvRiscof(
  YamlMap parent,
  String label,
  String filePath,
  List<ConfigLoaderError> errors,
  _RiscvExecutableGate gate,
) {
  final node = _riscvSubMap(parent, 'riscof', label, filePath, errors);
  if (node == null) return null;
  return RiscvRiscofConfig(
    command: _readRiscvStringList(
      node,
      'command',
      '$label.riscof',
      filePath,
      errors,
    ),
    pythonBinary: gate.read(node, 'binary', '$label.riscof', filePath, errors),
  );
}

RiscvSignatureConfig? _readRiscvSignature(
  YamlMap parent,
  String label,
  String filePath,
  List<ConfigLoaderError> errors,
) {
  final node = _riscvSubMap(parent, 'signature', label, filePath, errors);
  if (node == null) return null;
  final dut = _readRiscvString(
    node,
    'dut',
    '$label.signature',
    filePath,
    errors,
  );
  final reference = _readRiscvString(
    node,
    'reference',
    '$label.signature',
    filePath,
    errors,
  );
  // Same guard the `golden_compare` reader carries: pointing both at one
  // file would compare a dump against itself and always pass.
  if (dut != null && dut == reference) {
    errors.add(
      _error(
        path: filePath,
        node: node.nodes['dut'],
        message:
            '`$label.signature` points `dut` and `reference` at the same '
            'file ("$dut"), which would always pass. Give the reference '
            'signature a distinct path.',
      ),
    );
  }
  int? wordSize;
  final rawWordSize = node['word_size'];
  if (rawWordSize != null) {
    if (rawWordSize is int && rawWordSize > 0) {
      wordSize = rawWordSize;
    } else {
      errors.add(
        _error(
          path: filePath,
          node: node.nodes['word_size'],
          message:
              '`$label.signature.word_size` must be a positive integer number '
              'of bytes per signature word (got `$rawWordSize`). It is what '
              "turns the comparison's word offset into the byte offset the "
              'divergent instruction is decoded at.',
        ),
      );
    }
  }
  return RiscvSignatureConfig(
    dut: dut,
    reference: reference,
    wordSize: wordSize,
  );
}

RiscvFormalConfig? _readRiscvFormal(
  YamlMap parent,
  String label,
  String filePath,
  List<ConfigLoaderError> errors,
  _RiscvExecutableGate gate,
) {
  final node = _riscvSubMap(parent, 'formal', label, filePath, errors);
  if (node == null) return null;
  return RiscvFormalConfig(
    checksDir: _readRiscvString(
      node,
      'checks_dir',
      '$label.formal',
      filePath,
      errors,
    ),
    sbyBinary: gate.read(node, 'sby_binary', '$label.formal', filePath, errors),
    command: _readRiscvStringList(
      node,
      'command',
      '$label.formal',
      filePath,
      errors,
    ),
    demoOutputs: _readRiscvString(
      node,
      'demo_outputs',
      '$label.formal',
      filePath,
      errors,
    ),
    check: _readRiscvCheckName(node, '$label.formal', filePath, errors),
    sbyFile: _readRiscvString(
      node,
      'sby_file',
      '$label.formal',
      filePath,
      errors,
    ),
    task: _readRiscvString(node, 'task', '$label.formal', filePath, errors),
    group: _readRiscvString(node, 'group', '$label.formal', filePath, errors),
  );
}

/// Reads `formal.check`, refusing any value that is not one plain path
/// segment.
///
/// The `riscv_formal` driver names the proof's task directory after the
/// check (`<work_dir>/<check>`) and spawns `sby -f -d` on it, and `-f`
/// makes SymbiYosys delete that directory before it runs. `../..` climbs
/// out of the work dir and an absolute path replaces it outright (an
/// absolute second argument wins in `p.join`), so either would have `sby`
/// delete a directory SimCrux never created. A check name chooses no
/// program, so this is not behind the project-tooling gate: it is refused
/// whether or not project tooling is allowed.
///
/// Both separator spellings are refused on every host, so a project file
/// that loads on macOS cannot turn into a path on Windows.
String? _readRiscvCheckName(
  YamlMap node,
  String label,
  String filePath,
  List<ConfigLoaderError> errors,
) {
  final value = _readRiscvString(node, 'check', label, filePath, errors);
  if (value == null) return null;
  final problem = _riscvCheckNameProblem(value);
  if (problem == null) return value;
  errors.add(
    _error(
      path: filePath,
      node: node.nodes['check'],
      message:
          '`$label.check` must be a single file name, not a path (got '
          '"${value.replaceAll('\u0000', r'\0')}": $problem). It names the '
          'task directory `sby -f -d` deletes and recreates inside the '
          "test's working directory, so a path would have SymbiYosys delete "
          'a directory outside it. Use the riscv-formal check name, e.g. '
          '`insn_add_ch0`.',
    ),
  );
  return null;
}

/// Why [value] is not a single safe path segment, or null when it is.
String? _riscvCheckNameProblem(String value) {
  if (value.contains('\u0000')) return 'it contains a NUL byte';
  if (p.posix.isAbsolute(value) || p.windows.isAbsolute(value)) {
    return 'it is an absolute path';
  }
  if (value == '.' || value == '..') {
    return 'it names the working directory or its parent';
  }
  if (value.contains('/') || value.contains(r'\')) {
    return 'it contains a path separator';
  }
  return null;
}

/// Appends one error per completeness problem on the **flattened** config.
///
/// Called after all four merge steps, and only for tests that actually run
/// under one of the two RISC-V drivers: completeness is a property of the
/// merged config (a project may legitimately declare `target.command` once
/// in `defaults:` and only `test:` per test), and a `riscv:` block attached
/// to some other simulator is inert rather than wrong.
///
/// The two drivers share the block and need different keys out of it, so
/// the id selects which rules apply — `riscv_arch` never demands
/// `formal.sby_file`, and `riscv_formal` never demands `target.command`.
void _validateRiscvForTest({
  required RiscvConfig? riscv,
  required String simulatorId,
  required String suiteName,
  required String testName,
  required String filePath,
  required YamlNode? testNode,
  required List<ConfigLoaderError> errors,
}) {
  if (riscv == null) return;
  if (simulatorId != RiscvConfig.kSimulatorId &&
      simulatorId != RiscvConfig.kFormalSimulatorId) {
    return;
  }
  for (final problem in riscv.validateForRun(simulatorId: simulatorId)) {
    errors.add(
      _error(
        path: filePath,
        node: testNode,
        message: 'Test `$suiteName/$testName`: $problem',
      ),
    );
  }
}

// ── primitive readers, scoped to this part ─────────────────────────────
//
// Separate from `config_loader_readers.dart`'s helpers because these take a
// dotted label for the error message and report a *present but wrong type*
// value rather than silently returning null for it.

YamlMap? _riscvSubMap(
  YamlMap parent,
  String key,
  String label,
  String filePath,
  List<ConfigLoaderError> errors,
) {
  final raw = parent[key];
  if (raw == null) return null;
  if (raw is YamlMap) return raw;
  errors.add(
    _error(
      path: filePath,
      node: parent.nodes[key],
      message: '`$label.$key` must be a map.',
    ),
  );
  return null;
}

String? _readRiscvString(
  YamlMap node,
  String key,
  String label,
  String filePath,
  List<ConfigLoaderError> errors,
) {
  final raw = node[key];
  if (raw == null) return null;
  if (raw is String && raw.isNotEmpty) return raw;
  errors.add(
    _error(
      path: filePath,
      node: node.nodes[key],
      message: '`$label.$key` must be a non-empty string.',
    ),
  );
  return null;
}

List<String>? _readRiscvStringList(
  YamlMap node,
  String key,
  String label,
  String filePath,
  List<ConfigLoaderError> errors,
) {
  final raw = node.nodes[key];
  if (raw == null) return null;
  if (raw is! YamlList) {
    errors.add(
      _error(
        path: filePath,
        node: raw,
        message: '`$label.$key` must be a list of strings.',
      ),
    );
    return null;
  }
  final out = <String>[];
  for (final entry in raw.value) {
    if (entry is String && entry.isNotEmpty) {
      out.add(entry);
    } else if (entry is num || entry is bool) {
      // Numeric argv elements are common (`word_size`-ish flags, port
      // numbers) and unambiguous; accept them rather than making the user
      // quote every number.
      out.add(entry.toString());
    } else {
      errors.add(
        _error(
          path: filePath,
          node: raw,
          message: '`$label.$key` entries must be non-empty strings.',
        ),
      );
    }
  }
  return out;
}
