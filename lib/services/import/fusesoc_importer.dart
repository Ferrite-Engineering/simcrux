// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/fusesoc_import_result.dart';
import 'package:simcrux/domain/models/fusesoc_import_warning.dart';
import 'package:yaml/yaml.dart';

/// Imports a FuseSoC CAPI2 `.core` file into a SimCrux project file.
///
/// **Scope.** SimCrux reads — but never writes — CAPI2 files.
/// The importer is a one-way migration aid: drop a `.core` file next to
/// your project, get back a `simcrux.yaml` next to it. The native
/// format remains the canonical configuration for SimCrux users.
///
/// **Supported CAPI2 surface.**
///
/// - `name:` (`vendor:library:name:version`) — vendor/library/version
///   stripped to suggest a `simcrux.yaml` filename.
/// - `filesets.<name>.files` — list of source paths or
///   `{ <path>: { file_type: ..., is_include_file: ... } }` maps.
/// - `filesets.<name>.file_type` — fileset-level `file_type` applied
///   to every file in the set when the individual entry doesn't
///   override.
/// - `filesets.<name>.depend` — recursively expands into source list
///   ordering.
/// - `targets.<name>` — one SimCrux suite per *simulation* target.
///     - `targets.<name>.toplevel` → SimCrux test's `top:`.
///     - `targets.<name>.filesets` → source list (resolved through
///       the `filesets` table, dependencies first).
///     - `targets.<name>.parameters` → SimCrux `defines:` /
///       `parameters:` depending on the CAPI2 `parameters.<n>.paramtype`.
///     - `targets.<name>.flow` / `flow_options.tool` — the modern CAPI2
///       flow API. `flow: sim` selects the simulator from
///       `flow_options.tool`; any other flow (`synth`, `lint`, …) skips
///       the target.
///     - `targets.<name>.default_tool` → simulator id (mapped via
///       [_toolToSimulatorId]), consulted when `flow:` is absent.
///     - `targets.<name>.tools.<tool>` — first recognized tool wins
///       when `default_tool` is absent. Tools SimCrux can't run
///       (modelsim/questa/xsim/vcs) surface as warnings and fall back to
///       `icarus`; synthesis and place-and-route backends (vivado, ise,
///       quartus, icestorm, openlane, …) skip the target instead.
///
/// - `parameters.<name>` — datatype `int` / `str` / `bool` / `real`
///   accepted; complex types (`file`, generator types) warn and skip.
///
/// **Targets that do not become suites.** SimCrux runs testbenches, so
/// only simulation targets translate. Packaging targets (no `toplevel:`),
/// non-`sim` flows, and targets driven by a synthesis/P&R backend are
/// dropped — the last two with a `non_simulation_target` warning. A
/// board-support `.core` with forty FPGA targets and one simulation
/// therefore imports as one suite, not forty-one failing ones.
///
/// **Conditional expressions.** CAPI2 gates list entries with
/// `<flag>? (<value>)` and `!<flag>? (<value>)` — in `files`, `depend`,
/// a target's `filesets` and `parameters`, and `toplevel`. The importer
/// evaluates them per target: `is_toplevel` is true, `target_<name>` and
/// `tool_<id>` match the target being translated, and user-defined flags
/// (`mdu`, `vidbo`, …) are unset, as they are in FuseSoC absent
/// `--flag=+name`. Suppressed entries are dropped rather than emitted
/// verbatim — a `sources:` entry reading `tool_quartus? (foo.sv)` is a
/// filename no simulator can open.
///
/// **Unsupported features (warn + continue).**
///
/// - `vpi:` modules — VPI hooks aren't part of SimCrux's surface.
/// - `generators:` and generator targets — the FuseSoC pre-processor.
/// - `scripts:` — pre/post run hooks.
/// - `provides:` — FuseSoC package metadata.
/// - `tools.<vendor>` blocks for tools SimCrux can't run on Open Core.
/// - `file_type` values that aren't HDL (`tclSource`, `xdc`, …) — the
///   files are still listed in `sources:` so the user can clean them
///   up.
/// - `parameters.<name>` with `datatype: file` or generator types.
///
/// **Tool routing.**
///
/// | FuseSoC tool        | SimCrux simulator id |
/// |---------------------|----------------------|
/// | `icarus`            | `icarus`             |
/// | `verilator`         | `verilator`          |
/// | `ghdl`              | `ghdl`               |
/// | `cocotb`            | `cocotb`             |
/// | synthesis / P&R backend | target skipped (`non_simulation_target`) |
/// | any other simulator | warning + fall back to project's `defaults.simulator` |
///
/// The output `simcrux.yaml` is emitted directly as a string rather
/// than via a YAML serializer because (a) we want explicit control
/// over key ordering, (b) the comment block at the top of the file
/// attributes the import and lists every warning so the user has a
/// record of what didn't translate cleanly.
class FuseSoCImporter {
  /// Creates a [FuseSoCImporter].
  ///
  /// [readFile] is injected so tests can drive the importer off an
  /// in-memory string without touching the disk. The default
  /// implementation reads via `dart:io`.
  FuseSoCImporter({
    Future<String> Function(String path)? readFile,
  }) : _readFile = readFile ?? _defaultReadFile;

  final Future<String> Function(String path) _readFile;

  static Future<String> _defaultReadFile(String path) =>
      File(path).readAsString();

  /// Loads the CAPI2 `.core` file at [corePath] and translates it
  /// into a [FuseSoCImportResult] containing the synthesized
  /// SimCrux YAML and any non-fatal warnings.
  ///
  /// Throws [FuseSoCImportException] when the CAPI2 file is malformed
  /// in a way that prevents producing any output (missing `CAPI=2:`
  /// header, root not a map, no targets, malformed filesets).
  Future<FuseSoCImportResult> importFile(String corePath) async {
    final raw = await _readFile(corePath);
    return parse(raw, corePath);
  }

  /// Synchronous core. Translates [content] (the raw `.core` file
  /// text) into a [FuseSoCImportResult]. The [path] is used only for
  /// error messages and for deriving the suggested output filename
  /// when `name:` is absent.
  ///
  /// Throws [FuseSoCImportException] on unrecoverable parse errors.
  FuseSoCImportResult parse(String content, String path) {
    final warnings = <FuseSoCImportWarning>[];

    // CAPI2 header check — first non-blank line MUST be `CAPI=2:`.
    final lines = content.split('\n');
    final headerLine = lines.firstWhere(
      (l) => l.trim().isNotEmpty && !l.trimLeft().startsWith('#'),
      orElse: () => '',
    );
    if (!headerLine.trim().startsWith('CAPI=2:')) {
      throw FuseSoCImportException(
        path: path,
        message:
            'Not a CAPI2 file: first non-blank line must be `CAPI=2:` '
            '(got `${headerLine.trim()}`).',
      );
    }

    // YAML body starts after the CAPI=2: header. yaml package treats
    // `CAPI=2:` as a top-level scalar key with a null value, which
    // confuses downstream parsing. Strip it to the next colon-bearing
    // line.
    final headerIndex = lines.indexOf(headerLine);
    final body = lines.skip(headerIndex + 1).join('\n');

    final dynamic root;
    try {
      root = loadYaml(body.isEmpty ? '{}' : body, sourceUrl: Uri.file(path));
    } on YamlException catch (e) {
      throw FuseSoCImportException(
        path: path,
        message: 'YAML parse error: ${e.message}',
      );
    }
    if (root is! YamlMap) {
      throw FuseSoCImportException(
        path: path,
        message: 'Root must be a YAML map (got ${root.runtimeType}).',
      );
    }

    // ── identity ────────────────────────────────────────────────────
    final name = (root['name'] as String?)?.trim();
    final suggestedFilename = _suggestFilename(name: name, corePath: path);

    // ── filesets ────────────────────────────────────────────────────
    final filesetsNode = root['filesets'];
    final filesets = _parseFilesets(
      filesetsNode,
      path,
      warnings,
    );

    // ── parameters (project-level catalog) ──────────────────────────
    final parametersNode = root['parameters'];
    final parameterCatalog = _parseParameters(parametersNode, warnings);

    // ── targets → suites ────────────────────────────────────────────
    final targetsNode = root['targets'];
    if (targetsNode == null) {
      throw FuseSoCImportException(
        path: path,
        message: 'No `targets:` block found — nothing to import.',
      );
    }
    if (targetsNode is! YamlMap) {
      throw FuseSoCImportException(
        path: path,
        message: '`targets:` must be a map.',
      );
    }

    final suiteBlocks = <_SuiteBlock>[];
    for (final entry in targetsNode.entries) {
      final targetName = (entry.key as Object?)?.toString();
      final targetNode = entry.value;
      if (targetName == null || targetName.isEmpty) continue;
      if (targetNode is! YamlMap) {
        warnings.add(
          FuseSoCImportWarning(
            code: 'invalid_target',
            message: 'Target `$targetName` is not a map; skipping.',
          ),
        );
        continue;
      }
      final block = _translateTarget(
        targetName: targetName,
        targetNode: targetNode,
        filesets: filesets,
        parameterCatalog: parameterCatalog,
        warnings: warnings,
      );
      if (block != null) suiteBlocks.add(block);
    }

    if (suiteBlocks.isEmpty) {
      throw FuseSoCImportException(
        path: path,
        message:
            'No simulation targets in `targets:` — the import produced no '
            'suites. Packaging, synthesis, lint and place-and-route targets '
            'are skipped; check the importer warnings for what was dropped.',
      );
    }

    // ── top-level unsupported feature warnings ──────────────────────
    if (root.containsKey('vpi')) {
      warnings.add(
        const FuseSoCImportWarning(
          code: 'unsupported_vpi',
          message:
              '`vpi:` modules are not consumed by SimCrux; '
              'their declarations are ignored.',
        ),
      );
    }
    if (root.containsKey('generators') || root.containsKey('generate')) {
      warnings.add(
        const FuseSoCImportWarning(
          code: 'unsupported_generator',
          message:
              '`generators:` / `generate:` blocks are FuseSoC '
              "preprocessor steps and aren't run by SimCrux. Generated "
              'files referenced in filesets must be present at import '
              'time.',
        ),
      );
    }
    if (root.containsKey('scripts')) {
      warnings.add(
        const FuseSoCImportWarning(
          code: 'unsupported_scripts',
          message:
              '`scripts:` (pre/post run hooks) are not yet supported. '
              "Wrap them in a Makefile or move them into Cocotb's Makefile "
              'when porting to SimCrux.',
        ),
      );
    }

    // ── synthesize ──────────────────────────────────────────────────
    final yaml = _emit(
      sourceCorePath: path,
      suiteBlocks: suiteBlocks,
      warnings: warnings,
    );

    return FuseSoCImportResult(
      simcruxYaml: yaml,
      suggestedOutputFilename: suggestedFilename,
      warnings: warnings,
    );
  }

  // ── parsing helpers ─────────────────────────────────────────────────

  Map<String, _Fileset> _parseFilesets(
    Object? node,
    String path,
    List<FuseSoCImportWarning> warnings,
  ) {
    final out = <String, _Fileset>{};
    if (node == null) return out;
    if (node is! YamlMap) {
      warnings.add(
        const FuseSoCImportWarning(
          code: 'invalid_filesets',
          message: '`filesets:` is not a map; treating as empty.',
        ),
      );
      return out;
    }
    for (final entry in node.entries) {
      final name = (entry.key as Object?)?.toString();
      final raw = entry.value;
      if (name == null) continue;
      if (raw is! YamlMap) {
        warnings.add(
          FuseSoCImportWarning(
            code: 'invalid_fileset',
            message: 'Fileset `$name` is not a map; skipping.',
          ),
        );
        continue;
      }
      final defaultFileType = (raw['file_type'] as Object?)?.toString();
      final filesNode = raw['files'];
      final files = <_FilesetFile>[];
      if (filesNode is YamlList) {
        for (final fileEntry in filesNode) {
          final f = _parseFileEntry(
            entry: fileEntry,
            defaultFileType: defaultFileType,
            filesetName: name,
            warnings: warnings,
          );
          if (f != null) files.add(f);
        }
      } else if (filesNode != null) {
        warnings.add(
          FuseSoCImportWarning(
            code: 'invalid_files',
            message: 'Fileset `$name` has non-list `files:`; skipping.',
          ),
        );
      }
      final dependNode = raw['depend'];
      final depend = <String>[];
      if (dependNode is YamlList) {
        for (final d in dependNode) {
          if (d is String) depend.add(d);
        }
      }
      out[name] = _Fileset(name: name, files: files, depend: depend);
    }
    return out;
  }

  _FilesetFile? _parseFileEntry({
    required Object? entry,
    required String? defaultFileType,
    required String filesetName,
    required List<FuseSoCImportWarning> warnings,
  }) {
    // Bare string: `rtl/foo.v` — uses the fileset's `file_type`.
    if (entry is String) {
      if (entry.isEmpty) return null;
      return _FilesetFile(
        path: entry,
        fileType: defaultFileType,
        isInclude: false,
      );
    }
    // Map: `{ path/foo.v: { file_type: ..., is_include_file: ... } }`.
    if (entry is YamlMap) {
      if (entry.length != 1) {
        warnings.add(
          FuseSoCImportWarning(
            code: 'invalid_file_entry',
            message:
                'Fileset `$filesetName`: file map must have a single '
                'key (the path).',
          ),
        );
        return null;
      }
      final pathKey = entry.keys.first;
      if (pathKey is! String || pathKey.isEmpty) return null;
      final attrs = entry[pathKey];
      var fileType = defaultFileType;
      var isInclude = false;
      if (attrs is YamlMap) {
        final ft = attrs['file_type'];
        if (ft is String && ft.isNotEmpty) fileType = ft;
        final inc = attrs['is_include_file'];
        if (inc is bool) isInclude = inc;
      }
      return _FilesetFile(
        path: pathKey,
        fileType: fileType,
        isInclude: isInclude,
      );
    }
    return null;
  }

  Map<String, _ParameterSpec> _parseParameters(
    Object? node,
    List<FuseSoCImportWarning> warnings,
  ) {
    final out = <String, _ParameterSpec>{};
    if (node == null) return out;
    if (node is! YamlMap) return out;
    for (final entry in node.entries) {
      final name = (entry.key as Object?)?.toString();
      final raw = entry.value;
      if (name == null) continue;
      if (raw is! YamlMap) continue;
      final datatype = (raw['datatype'] as Object?)?.toString();
      final paramtype = (raw['paramtype'] as Object?)?.toString();
      final defaultRaw = raw['default'];
      final isComplex = datatype == 'file' || datatype == 'file_list';
      if (isComplex) {
        warnings.add(
          FuseSoCImportWarning(
            code: 'complex_parameter',
            message:
                'Parameter `$name` has datatype `$datatype` which '
                "doesn't map cleanly to SimCrux's defines/parameters. "
                'Skipping.',
          ),
        );
        continue;
      }
      out[name] = _ParameterSpec(
        name: name,
        datatype: datatype,
        paramtype: paramtype,
        defaultValue: defaultRaw?.toString(),
      );
    }
    return out;
  }

  _SuiteBlock? _translateTarget({
    required String targetName,
    required YamlMap targetNode,
    required Map<String, _Fileset> filesets,
    required Map<String, _ParameterSpec> parameterCatalog,
    required List<FuseSoCImportWarning> warnings,
  }) {
    // CAPI2 spec lets a target omit `toplevel:` (it's a packaging-only
    // target). We skip those without warning — a user expects only
    // simulation targets to translate to suites. The value itself is
    // resolved further down, once the flag context exists.
    final toplevelNode = targetNode['toplevel'];
    if (toplevelNode == null) return null;

    // Tool routing. Modern CAPI2 declares `flow:` plus `flow_options.tool`;
    // legacy CAPI2 uses `default_tool:` / `tools:`. Either way, a target
    // only becomes a SimCrux suite when it describes a *simulation* —
    // synthesis, lint and place-and-route targets have no testbench, and
    // handing their sources to a simulator manufactures a suite that can
    // never pass.
    final flow = (targetNode['flow'] as Object?)?.toString();
    String? toolId;
    if (flow != null && flow.isNotEmpty) {
      if (flow.toLowerCase() != 'sim') {
        warnings.add(
          FuseSoCImportWarning(
            code: 'non_simulation_target',
            message:
                'Target `$targetName` declares `flow: $flow`, which is not '
                'a simulation; skipping. SimCrux runs testbenches, not '
                'synthesis or lint flows.',
          ),
        );
        return null;
      }
      final flowOptions = targetNode['flow_options'];
      if (flowOptions is YamlMap) {
        toolId = (flowOptions['tool'] as Object?)?.toString();
      }
    }
    toolId ??= (targetNode['default_tool'] as Object?)?.toString();
    final toolsNode = targetNode['tools'];
    if (toolsNode is YamlMap) {
      final declaredTools = <String>[];
      for (final k in toolsNode.keys) {
        if (k is String) declaredTools.add(k);
      }
      // When no `default_tool`, pick the first declared tool.
      if (toolId == null && declaredTools.isNotEmpty) {
        toolId = declaredTools.first;
      }
    }
    final simulatorId = _toolToSimulatorId(toolId, warnings, targetName);
    if (simulatorId == null) return null;

    // Flags are decidable only now: `tool_*` depends on the tool this
    // target resolved to, so every list in the target is expanded from
    // here down rather than at project-parse time.
    final flags = _FlagContext(targetName: targetName, toolId: toolId);
    final reportedFlags = <String>{};

    // `toplevel:` is a scalar in most core files but CAPI2 permits a
    // list, and either form may carry a conditional — SERV writes
    // `toplevel: ["is_toplevel? (serv_rf_top)"]`. Take the first entry
    // that survives expansion.
    final toplevelCandidates = <String>[];
    if (toplevelNode is YamlList) {
      for (final t in toplevelNode) {
        if (t != null) toplevelCandidates.add(t.toString());
      }
    } else {
      toplevelCandidates.add(toplevelNode.toString());
    }
    String? toplevel;
    for (final candidate in toplevelCandidates) {
      final expanded = _expandConditional(
        candidate,
        flags,
        what: 'toplevel',
        warnings: warnings,
        reportedFlags: reportedFlags,
      );
      if (expanded.isNotEmpty) {
        toplevel = expanded.first;
        break;
      }
    }
    if (toplevel == null || toplevel.isEmpty) {
      warnings.add(
        FuseSoCImportWarning(
          code: 'unresolved_toplevel',
          message:
              'Target `$targetName` has a `toplevel:` that resolves to '
              'nothing under the import-time flags; skipping the target.',
        ),
      );
      return null;
    }

    // Resolve filesets → ordered source list.
    final filesetNamesNode = targetNode['filesets'];
    final filesetNames = <String>[];
    if (filesetNamesNode is YamlList) {
      for (final n in filesetNamesNode) {
        if (n is String && n.isNotEmpty) filesetNames.add(n);
      }
    }
    final sources = _resolveSources(
      filesetNames: filesetNames,
      filesets: filesets,
      warnings: warnings,
      targetName: targetName,
      flags: flags,
      reportedFlags: reportedFlags,
    );

    // CAPI2 parameters on the target — list of `KEY` (use default) or
    // `KEY=VALUE`.
    final paramsNode = targetNode['parameters'];
    final defines = <String, String>{};
    final parameters = <String, String>{};
    if (paramsNode is YamlList) {
      final expandedParams = <String>[
        for (final entry in paramsNode)
          if (entry is String && entry.isNotEmpty)
            ..._expandConditional(
              entry,
              flags,
              what: 'parameter',
              warnings: warnings,
              reportedFlags: reportedFlags,
            ),
      ];
      for (final entry in expandedParams) {
        final eq = entry.indexOf('=');
        final paramName = eq < 0 ? entry : entry.substring(0, eq);
        final paramValue = eq < 0
            ? parameterCatalog[paramName]?.defaultValue ?? ''
            : entry.substring(eq + 1);
        final spec = parameterCatalog[paramName];
        if (spec == null) {
          // Unknown parameter — fall back to SimCrux defines so the
          // target still loads. Surface a soft warning.
          warnings.add(
            FuseSoCImportWarning(
              code: 'unknown_parameter',
              message:
                  'Target `$targetName` references undeclared '
                  'parameter `$paramName`; treating as `defines:`.',
            ),
          );
          defines[paramName] = paramValue;
          continue;
        }
        switch (spec.paramtype) {
          case 'vlogdefine':
            defines[paramName] = paramValue;
          case 'vlogparam':
          case 'generic':
            parameters[paramName] = paramValue;
          case 'plusarg':
          case 'cmdlinearg':
            // SimCrux's TestSpec doesn't have a first-class plusargs
            // field yet; surface the warning and drop into parameters
            // so the user can hand-edit.
            warnings.add(
              FuseSoCImportWarning(
                code: 'plusarg_parameter',
                message:
                    'Parameter `$paramName` (paramtype=`${spec.paramtype}`) '
                    'has no first-class SimCrux mapping; emitting under '
                    '`parameters:` for manual review.',
              ),
            );
            parameters[paramName] = paramValue;
          default:
            // No paramtype declared → guess by datatype.
            if (spec.datatype == 'int' || spec.datatype == 'real') {
              parameters[paramName] = paramValue;
            } else {
              defines[paramName] = paramValue;
            }
        }
      }
    }

    return _SuiteBlock(
      suiteName: targetName,
      simulatorId: simulatorId,
      top: toplevel,
      sources: sources,
      defines: defines,
      parameters: parameters,
    );
  }

  List<String> _resolveSources({
    required List<String> filesetNames,
    required Map<String, _Fileset> filesets,
    required List<FuseSoCImportWarning> warnings,
    required String targetName,
    required _FlagContext flags,
    required Set<String> reportedFlags,
  }) {
    final visited = <String>{};
    final out = <String>[];
    List<String> expand(String raw, String what) => _expandConditional(
      raw,
      flags,
      what: what,
      warnings: warnings,
      reportedFlags: reportedFlags,
    );
    void walk(String name) {
      if (visited.contains(name)) return;
      visited.add(name);
      final fs = filesets[name];
      if (fs == null) {
        warnings.add(
          FuseSoCImportWarning(
            code: 'unknown_fileset',
            message:
                'Target `$targetName` references unknown fileset '
                '`$name`; skipping.',
          ),
        );
        return;
      }
      // `depend:` entries are themselves conditional-bearing, and a
      // dependency on another core (`vendor:lib:name`) is not a fileset
      // in this file — both must be filtered before the recursion.
      for (final d in fs.depend) {
        expand(d, 'fileset dependency').forEach(walk);
      }
      for (final f in fs.files) {
        // Resolve the conditional before warning about the entry: a file
        // this target never compiles should not generate advice about a
        // file type it will never see.
        for (final path in expand(f.path, 'source file')) {
          // Include directives are not mapped onto `defines:`-adjacent
          // include_dirs; the importer
          // warns and includes the file in the source list (the simulator
          // will pick it up either way under most flows).
          if (f.isInclude) {
            warnings.add(
              FuseSoCImportWarning(
                code: 'include_file_demotion',
                message:
                    'Fileset `$name`: file `$path` is marked '
                    '`is_include_file: true`; emitting under `sources:`. '
                    'Move it into `include_dirs:` by hand if needed.',
              ),
            );
          }
          if (_isNonHdlFileType(f.fileType)) {
            warnings.add(
              FuseSoCImportWarning(
                code: 'non_hdl_file_type',
                message:
                    'Fileset `$name`: file `$path` has '
                    '`file_type: ${f.fileType}` which is not HDL. '
                    'Listed in `sources:` for inspection; remove if '
                    "your simulator can't consume it.",
              ),
            );
          }
          out.add(path);
        }
      }
    }

    for (final n in filesetNames) {
      expand(n, 'fileset').forEach(walk);
    }
    return out;
  }

  /// Matches a CAPI2 conditional expression: `flag? (value)` or
  /// `!flag? (value)`. The value may hold several whitespace-separated
  /// tokens, which is how FuseSoC gates a group of files on one flag.
  static final _conditional = RegExp(
    r'^\s*(!)?\s*([A-Za-z_][A-Za-z0-9_]*)\s*\?\s*\((.*)\)\s*$',
  );

  /// Expands one CAPI2 list entry against [flags].
  ///
  /// A plain entry expands to itself. A conditional expands to its
  /// value(s) when the condition holds and to nothing when it does not —
  /// which is the whole point: `tool_quartus? (servant_ram_quartus.sv)`
  /// must vanish from an Icarus run rather than reach the simulator as a
  /// filename with a `?` in it.
  ///
  /// [what] names the kind of entry (`file`, `parameter`, …) for the
  /// warning emitted when an unknown user flag suppresses something.
  List<String> _expandConditional(
    String raw,
    _FlagContext flags, {
    required String what,
    required List<FuseSoCImportWarning> warnings,
    required Set<String> reportedFlags,
  }) {
    final m = _conditional.firstMatch(raw);
    if (m == null) return [raw];

    final negated = m.group(1) != null;
    final flag = m.group(2)!;
    final value = m.group(3)!;

    final holds = flags.isSet(flag) != negated;
    if (holds) {
      return value.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    }

    // Suppressed. Only worth reporting when the importer is *assuming*
    // the flag is unset — a `tool_*` mismatch is a fact, not a guess.
    if (!flags.isKnown(flag) &&
        reportedFlags.add('${flags.targetName}:$flag')) {
      warnings.add(
        FuseSoCImportWarning(
          code: 'conditional_flag_unset',
          message:
              'Target `${flags.targetName}`: entries gated on the '
              'user-defined flag `$flag` were dropped ($what). FuseSoC '
              'leaves such flags unset unless invoked with '
              '`--flag=+$flag`; add the entries by hand if you want them.',
        ),
      );
    }
    return const [];
  }

  /// CAPI2 tool ids that are synthesis, lint or place-and-route
  /// backends rather than simulators. A target driven by one of these
  /// has no testbench to run, so it is skipped outright.
  static const _nonSimulationTools = <String>{
    'apicula',
    'ascentlint',
    'diamond',
    'f4pga',
    'gowin',
    'icestorm',
    'ise',
    'libero',
    'mistral',
    'morty',
    'netlistsvg',
    'nextpnr',
    'openlane',
    'oxide',
    'quartus',
    'radiant',
    'spyglass',
    'symbiflow',
    'symbiyosys',
    'trellis',
    'veribleformat',
    'veriblelint',
    'vivado',
    'vpr',
    'yosys',
  };

  /// Maps a CAPI2 tool id to SimCrux's simulator id.
  ///
  /// Returns `null` when the tool is a synthesis / lint / place-and-route
  /// backend — the caller drops the target rather than emitting a suite.
  /// Simulators SimCrux can't drive yet (modelsim, questa, xsim, vcs, …)
  /// still fall back to `icarus` with a warning: substituting one Verilog
  /// simulator for another is lossy but coherent, whereas running a
  /// bitstream flow under a simulator is not.
  String? _toolToSimulatorId(
    String? toolId,
    List<FuseSoCImportWarning> warnings,
    String targetName,
  ) {
    if (toolId == null) return 'icarus';
    final id = toolId.toLowerCase();
    switch (id) {
      case 'icarus':
        return 'icarus';
      case 'verilator':
        return 'verilator';
      case 'ghdl':
        return 'ghdl';
      case 'cocotb':
        return 'cocotb';
      default:
        if (_nonSimulationTools.contains(id)) {
          warnings.add(
            FuseSoCImportWarning(
              code: 'non_simulation_target',
              message:
                  'Target `$targetName` is driven by `$toolId`, a '
                  'synthesis/place-and-route backend rather than a '
                  'simulator; skipping. SimCrux runs testbenches.',
            ),
          );
          return null;
        }
        warnings.add(
          FuseSoCImportWarning(
            code: 'unsupported_tool',
            message:
                'Target `$targetName` uses tool `$toolId` which '
                "SimCrux Open Core can't run. Falling back to `icarus`; "
                'switch to a Pro driver after import.',
          ),
        );
        return 'icarus';
    }
  }

  /// Returns true when [fileType] is a CAPI2 `file_type` value that
  /// isn't an HDL source. The importer keeps the file in the source
  /// list (so the user sees what was in the FuseSoC file) but warns
  /// — simulators generally can't compile these.
  bool _isNonHdlFileType(String? fileType) {
    if (fileType == null) return false;
    switch (fileType) {
      case 'verilogSource':
      case 'verilogSource-95':
      case 'verilogSource-2001':
      case 'verilogSource-2005':
      case 'systemVerilogSource':
      case 'systemVerilogSource-3.0':
      case 'systemVerilogSource-3.1':
      case 'systemVerilogSource-3.1a':
      case 'systemVerilogSource-2005':
      case 'systemVerilogSource-2009':
      case 'systemVerilogSource-2012':
      case 'systemVerilogSource-2017':
      case 'vhdlSource':
      case 'vhdlSource-87':
      case 'vhdlSource-93':
      case 'vhdlSource-2008':
      case 'vhdlSource-2019':
      case 'user':
        return false;
      default:
        return true;
    }
  }

  String _suggestFilename({required String? name, required String corePath}) {
    // The output is named after the core it came from, because the
    // caller writes it next to the `.core` file and multi-core
    // directories are the norm, not an edge case: SERV ships `serv.core`,
    // `servant.core`, `servile.core` and `serving.core` side by side. A
    // fixed `simcrux.yaml` made every import after the first silently
    // overwrite its predecessor, and — because the workspace de-dupes
    // tabs by config path — reuse the open tab so the screen kept showing
    // the *previous* core's suites.
    //
    // `vendor:library:name:version` contributes its name field; a bare
    // `name:` is used as-is; a core with no usable `name:` falls back to
    // the `.core` file's own basename.
    final fromName = name == null || name.isEmpty
        ? null
        : (name.contains(':') ? name.split(':')[2] : name).trim();
    final stem = (fromName == null || fromName.isEmpty)
        ? p.basenameWithoutExtension(corePath)
        : fromName;
    final safe = stem.replaceAll(RegExp('[^A-Za-z0-9_.-]'), '_');
    return safe.isEmpty ? 'simcrux.yaml' : '$safe.simcrux.yaml';
  }

  // ── output emission ─────────────────────────────────────────────────

  String _emit({
    required String sourceCorePath,
    required List<_SuiteBlock> suiteBlocks,
    required List<FuseSoCImportWarning> warnings,
  }) {
    final buf = StringBuffer()
      ..writeln(
        '# Generated by SimCrux FuseSoC importer from '
        '${p.basename(sourceCorePath)}.',
      )
      ..writeln(
        '# Review before committing: SimCrux reads CAPI2 but only '
        'consumes a subset.',
      )
      ..writeln('# Source: $sourceCorePath');

    if (warnings.isNotEmpty) {
      buf
        ..writeln('# ')
        ..writeln(
          '# Import warnings (${warnings.length}) — features the importer '
          'could not translate fully:',
        );
      for (final w in warnings) {
        buf.writeln('#   [${w.code}] ${w.message}');
      }
    }

    buf
      ..writeln()
      ..writeln("version: '1'")
      ..writeln()
      ..writeln('defaults:')
      ..writeln('  simulator: icarus')
      ..writeln('  pass_fail:')
      ..writeln('    type: exit_code')
      ..writeln('  waveform:')
      ..writeln('    capture: on_failure')
      ..writeln()
      ..writeln('suites:');

    for (final block in suiteBlocks) {
      buf
        ..writeln('  ${_yamlSafeKey(block.suiteName)}:')
        ..writeln(
          '    description: '
          'Imported from FuseSoC target `${block.suiteName}`.',
        )
        ..writeln('    simulator: ${block.simulatorId}')
        ..writeln('    tests:')
        ..writeln('      - name: ${_yamlSafeKey(block.suiteName)}_main')
        ..writeln('        top: ${block.top}');
      if (block.sources.isNotEmpty) {
        buf.writeln('        sources:');
        for (final s in block.sources) {
          buf.writeln('          - ${_yamlSafeScalar(s)}');
        }
      }
      if (block.defines.isNotEmpty) {
        buf.writeln('        defines:');
        final sorted = block.defines.keys.toList()..sort();
        for (final k in sorted) {
          buf.writeln('          $k: ${_yamlSafeScalar(block.defines[k]!)}');
        }
      }
      if (block.parameters.isNotEmpty) {
        buf.writeln('        parameters:');
        final sorted = block.parameters.keys.toList()..sort();
        for (final k in sorted) {
          buf.writeln(
            '          $k: ${_yamlSafeScalar(block.parameters[k]!)}',
          );
        }
      }
    }

    return buf.toString();
  }

  /// Returns a key suitable for YAML emission. Replaces characters
  /// that would confuse a downstream parser with underscores.
  String _yamlSafeKey(String key) {
    if (key.isEmpty) return 'imported';
    return key.replaceAll(RegExp('[^A-Za-z0-9_-]'), '_');
  }

  /// Returns a scalar suitable for YAML emission. Wraps in single
  /// quotes when the value contains characters that would require it
  /// (spaces, leading dashes, colons), otherwise returns as-is.
  String _yamlSafeScalar(String value) {
    if (value.isEmpty) return "''";
    // Match any character that would force YAML to quote the scalar.
    final needsQuote = RegExp(
      '[:#&*!|>\'"%@`{}\\[\\],?\\s]|^-',
    ).hasMatch(value);
    if (!needsQuote) return value;
    final escaped = value.replaceAll("'", "''");
    return "'$escaped'";
  }
}

/// Thrown by [FuseSoCImporter] when the `.core` file cannot be
/// translated at all (missing CAPI2 header, malformed top-level
/// structure, no targets). Non-fatal issues surface as
/// [FuseSoCImportResult.warnings] instead.
class FuseSoCImportException implements Exception {
  /// Creates a [FuseSoCImportException].
  const FuseSoCImportException({required this.path, required this.message});

  /// Path of the offending `.core` file.
  final String path;

  /// Human-readable description.
  final String message;

  @override
  String toString() => 'FuseSoCImportException ($path): $message';
}

// ── internal carriers ────────────────────────────────────────────────

/// The CAPI2 flags in scope while translating one target.
///
/// FuseSoC gates list entries on flags with `<flag>? (<value>)`. Three
/// families are decidable at import time:
///
/// - `is_toplevel` — true. Importing a `.core` means running *it*, which
///   is exactly the condition FuseSoC uses the flag for.
/// - `target_<name>` — true for the target being translated.
/// - `tool_<id>` — true for the tool this target resolved to.
///
/// Everything else is a user-defined flag (`mdu`, `vidbo`, …). FuseSoC
/// leaves those unset unless the user passes `--flag=+name`, so the
/// importer treats them as unset and records a warning naming the flag,
/// giving the user something to grep for if they wanted it on.
class _FlagContext {
  const _FlagContext({required this.targetName, required this.toolId});

  final String targetName;
  final String? toolId;

  bool isSet(String flag) =>
      flag == 'is_toplevel' ||
      flag == 'target_$targetName' ||
      (toolId != null && flag == 'tool_$toolId');

  /// True for flags whose value the importer genuinely knows, as opposed
  /// to user-defined flags it is merely assuming are unset.
  bool isKnown(String flag) =>
      flag == 'is_toplevel' ||
      flag.startsWith('target_') ||
      flag.startsWith('tool_');
}

class _Fileset {
  _Fileset({
    required this.name,
    required this.files,
    required this.depend,
  });

  final String name;
  final List<_FilesetFile> files;
  final List<String> depend;
}

class _FilesetFile {
  _FilesetFile({
    required this.path,
    required this.fileType,
    required this.isInclude,
  });

  final String path;
  final String? fileType;
  final bool isInclude;
}

class _ParameterSpec {
  _ParameterSpec({
    required this.name,
    required this.datatype,
    required this.paramtype,
    required this.defaultValue,
  });

  final String name;
  final String? datatype;
  final String? paramtype;
  final String? defaultValue;
}

class _SuiteBlock {
  _SuiteBlock({
    required this.suiteName,
    required this.simulatorId,
    required this.top,
    required this.sources,
    required this.defines,
    required this.parameters,
  });

  final String suiteName;
  final String simulatorId;
  final String top;
  final List<String> sources;
  final Map<String, String> defines;
  final Map<String, String> parameters;
}
