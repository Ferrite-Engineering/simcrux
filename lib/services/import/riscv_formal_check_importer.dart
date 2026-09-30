// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/riscv_run_mode.dart';
import 'package:simcrux/domain/models/riscv_config.dart';
import 'package:simcrux/domain/models/riscv_import_result.dart';
import 'package:simcrux/domain/models/sby_outcome.dart';
import 'package:simcrux/domain/models/sby_script.dart';

/// Enumerates a riscv-formal check set into **one SimCrux `TestSpec` per
/// bounded proof**, emitted as inspectable `simcrux.yaml`.
///
/// ## Why an importer and not a driver loop
///
/// The same argument `RiscvArchTestImporter` makes for the architectural
/// suite, and it is not
/// weaker here. The job model has no fan-out — one `TestSpec` yields
/// exactly one `TestExecutionFinished` and exactly one `TestResult` — and
/// riscv-formal's own flow (`genchecks.py` then `make -C checks`) runs
/// dozens of independent `sby` jobs. Resolving that inside a driver would
/// forfeit per-proof scheduling, per-proof timeouts, cancellation and
/// progress, and the dashboard would show one row that either passed or
/// failed for an hour.
///
/// So the enumeration happens **before** the scheduler, following the
/// `FuseSoCImporter` / [RiscvArchTestImporter] precedent: read the
/// ecosystem's own artifacts, emit a SimCrux config the user can read,
/// diff, edit and commit — rather than hiding the mapping inside a driver
/// where a mis-tagged property group or a skipped check is invisible.
///
/// ## What it reads
///
/// riscv-formal's `checks/genchecks.py` turns `checks.cfg` into one
/// `.sby` file per check per RVFI channel:
///
/// ```text
/// cores/<core>/checks/
///   insn_add_ch0.sby
///   insn_addi_ch0.sby
///   pc_fwd_ch0.sby
///   reg_ch0.sby
///   …
/// ```
///
/// Enumerating the **generated `.sby` files** rather than parsing
/// `checks.cfg` is deliberate: the `.sby` files are what actually runs,
/// they already encode the channel expansion, and a user who hand-edited
/// one gets the edited proof rather than a re-derivation of it.
///
/// A `.sby` that declares a `[tasks]` section becomes **one test per
/// task**, because a single invocation running every task would print
/// several `DONE (…)` lines and re-create exactly the fan-out this
/// importer exists to prevent.
///
/// ## `top:` is synthesized, and that is mandatory
///
/// `top:` is a required `TestSpec` field and a bounded proof has no HDL
/// top level of SimCrux's own choosing — the `.sby` script picks one. The
/// importer synthesizes the check name. An importer that omitted it would
/// emit a config the loader refuses.
///
/// ## The detector it emits, and why that one
///
/// `pass_fail: { type: string_match, pass_string: 'DONE (PASS' }`.
///
/// The string-match detector's documented semantics are exactly right
/// here: a required pass string that never appears is a **fail**, not an
/// `unknown` that would fall back to the driver's status and let an
/// `sby` that exited 0 without proving anything read as green. And the
/// literal is [SbyLogReader.kPassMarker] — the same constant the driver's
/// parser recognizes — so detector and driver agree **by construction**,
/// which is the shared-convention move the compatibility path makes with
/// the signature filenames.
class RiscvFormalCheckImporter {
  /// Creates a [RiscvFormalCheckImporter].
  ///
  /// [listDirectory] and [readFile] are injected so tests drive the
  /// importer against an in-memory tree; production walks the real
  /// filesystem.
  RiscvFormalCheckImporter({
    List<String> Function(String dir)? listDirectory,
    String Function(String path)? readFile,
    bool Function(String path)? directoryExists,
  }) : _listDirectory = listDirectory ?? _defaultListDirectory,
       _readFile = readFile ?? _defaultReadFile,
       _directoryExists = directoryExists ?? _defaultDirectoryExists;

  final List<String> Function(String dir) _listDirectory;
  final String Function(String path) _readFile;
  final bool Function(String path) _directoryExists;

  /// Conventional subdirectory `genchecks.py` writes its jobs into.
  static const String kChecksSubdir = 'checks';

  static List<String> _defaultListDirectory(String dir) {
    final directory = Directory(dir);
    if (!directory.existsSync()) return const <String>[];
    return directory.listSync().map((e) => e.path).toList(growable: false)
      ..sort();
  }

  static String _defaultReadFile(String path) => File(path).readAsStringSync();

  static bool _defaultDirectoryExists(String path) =>
      Directory(path).existsSync();

  // ── the real check set ─────────────────────────────────────────────

  /// Enumerates the generated `.sby` files under [checksPath].
  ///
  /// [groups], when non-empty, restricts the import to those property
  /// groups (`insn`, `reg`, `pc_fwd`, …), case-insensitively. [defaults]
  /// supplies the shared `riscv:` plumbing that lands once under
  /// `defaults.riscv` and is inherited by every test.
  ///
  /// Throws [RiscvImportException] when the path is not a check
  /// directory, or when the scan produced no proofs at all — which is
  /// always a wrong-path or forgot-to-run-`genchecks.py` mistake rather
  /// than an empty-but-valid check set.
  RiscvImportResult importChecks({
    required String checksPath,
    RiscvConfig defaults = const RiscvConfig(),
    List<String> groups = const <String>[],
  }) {
    final warnings = <RiscvImportWarning>[];
    final absPath = p.normalize(p.absolute(checksPath));
    if (!_directoryExists(absPath)) {
      throw RiscvImportException(
        path: absPath,
        message:
            'Not a directory — point at the `checks/` directory '
            '`genchecks.py` wrote, or at the core directory containing it.',
      );
    }
    // Accept a core directory that contains `checks/` as well as the
    // `checks/` directory itself.
    final withSubdir = p.join(absPath, kChecksSubdir);
    final scanRoot = _directoryExists(withSubdir) ? withSubdir : absPath;

    final wanted = groups.map((g) => g.toLowerCase()).toSet();
    final byGroup = <String, List<_FormalCheck>>{};
    for (final entry in _listDirectory(scanRoot)) {
      if (p.extension(entry).toLowerCase() != '.sby') continue;
      final check = p.basenameWithoutExtension(entry);
      final group = RiscvFormalConfig.groupForCheck(check) ?? 'checks';
      if (wanted.isNotEmpty && !wanted.contains(group.toLowerCase())) continue;
      final script = _parseScript(entry);
      final file = p.basename(entry);
      if (script.tasks.isEmpty) {
        byGroup
            .putIfAbsent(group, () => <_FormalCheck>[])
            .add(_FormalCheck(name: check, sbyFile: file, group: group));
        continue;
      }
      // One test per task: a multi-task `.sby` run in one invocation
      // would emit several `DONE (…)` lines into one result row.
      warnings.add(
        RiscvImportWarning(
          code: 'multi_task_sby',
          message:
              '`$file` declares ${script.tasks.length} tasks, so it was '
              'expanded into one test per task. A single `sby` invocation '
              'over all of them would report several verdicts into one '
              'result row.',
        ),
      );
      for (final task in script.tasks) {
        byGroup
            .putIfAbsent(group, () => <_FormalCheck>[])
            .add(
              _FormalCheck(
                name: '${check}_$task',
                sbyFile: file,
                group: group,
                task: task,
              ),
            );
      }
    }

    if (byGroup.isEmpty) {
      throw RiscvImportException(
        path: scanRoot,
        message:
            'No `.sby` job files found beneath this path'
            '${groups.isEmpty ? '' : ' for groups ${groups.join(', ')}'}. '
            'riscv-formal generates them with '
            '`python3 checks/genchecks.py`; run that first.',
      );
    }

    final orderedGroups = byGroup.keys.toList()..sort();
    final effectiveDefaults = defaults.copyWith(
      formal: (defaults.formal ?? const RiscvFormalConfig()).mergeOnto(
        RiscvFormalConfig(checksDir: scanRoot),
      ),
    );
    final yaml = _emit(
      sourceLabel: scanRoot,
      defaults: effectiveDefaults,
      byGroup: byGroup,
      orderedGroups: orderedGroups,
      warnings: warnings,
    );
    return RiscvImportResult(
      simcruxYaml: yaml,
      suggestedOutputFilename: 'simcrux.yaml',
      testCount: byGroup.values.fold(0, (a, b) => a + b.length),
      extensions: orderedGroups,
      warnings: warnings,
    );
  }

  // ── demo mode ──────────────────────────────────────────────────────

  /// Enumerates a committed pre-captured SymbiYosys output corpus into
  /// the same shape, for [RiscvRunMode.demo].
  ///
  /// Each immediate subdirectory of [demoOutputsPath] is one case, and
  /// its `case.json` supplies the captured log filename, any trace files,
  /// and the group tag. This is how CI tests the driver and how the
  /// formal dashboard is demoed offline: no Yosys, no SymbiYosys, no SMT
  /// solver, no network, and the identical driver code path.
  RiscvImportResult importDemo({
    required String demoOutputsPath,
    RiscvConfig defaults = const RiscvConfig(),
    String fallbackGroup = 'insn',
  }) {
    final warnings = <RiscvImportWarning>[];
    final absRoot = p.normalize(p.absolute(demoOutputsPath));
    if (!_directoryExists(absRoot)) {
      throw RiscvImportException(
        path: absRoot,
        message:
            'Not a directory — point at a corpus of pre-captured SymbiYosys '
            'outputs (one subdirectory per case).',
      );
    }
    final byGroup = <String, List<_FormalCheck>>{};
    for (final entry in _listDirectory(absRoot)) {
      if (!_directoryExists(entry)) continue;
      final caseName = p.basename(entry);
      final manifest = _demoManifest(entry);
      final check = manifest['check'] is String
          ? manifest['check']! as String
          : caseName;
      final group = manifest['group'] is String
          ? manifest['group']! as String
          : (RiscvFormalConfig.groupForCheck(check) ?? fallbackGroup);
      byGroup
          .putIfAbsent(group, () => <_FormalCheck>[])
          .add(
            _FormalCheck(
              name: caseName,
              sbyFile: null,
              group: group,
              check: check,
              demoCase: caseName,
            ),
          );
    }
    if (byGroup.isEmpty) {
      throw RiscvImportException(
        path: absRoot,
        message: 'No case subdirectories found under this path.',
      );
    }

    final orderedGroups = byGroup.keys.toList()..sort();
    final effectiveDefaults = defaults.copyWith(
      mode: RiscvRunMode.demo,
      formal: (defaults.formal ?? const RiscvFormalConfig()).mergeOnto(
        RiscvFormalConfig(demoOutputs: absRoot),
      ),
    );
    final yaml = _emit(
      sourceLabel: absRoot,
      defaults: effectiveDefaults,
      byGroup: byGroup,
      orderedGroups: orderedGroups,
      warnings: warnings,
      demo: true,
    );
    return RiscvImportResult(
      simcruxYaml: yaml,
      suggestedOutputFilename: 'simcrux.yaml',
      testCount: byGroup.values.fold(0, (a, b) => a + b.length),
      extensions: orderedGroups,
      warnings: warnings,
    );
  }

  // ── reading ────────────────────────────────────────────────────────

  SbyScript _parseScript(String path) {
    try {
      return SbyScript.parse(_readFile(path));
    } on Object {
      return const SbyScript();
    }
  }

  Map<String, Object?> _demoManifest(String caseDir) {
    try {
      final decoded = jsonDecode(_readFile(p.join(caseDir, 'case.json')));
      if (decoded is Map<String, Object?>) return decoded;
      return const <String, Object?>{};
    } on Object {
      return const <String, Object?>{};
    }
  }

  // ── emission ───────────────────────────────────────────────────────

  String _emit({
    required String sourceLabel,
    required RiscvConfig defaults,
    required Map<String, List<_FormalCheck>> byGroup,
    required List<String> orderedGroups,
    required List<RiscvImportWarning> warnings,
    bool demo = false,
  }) {
    final buf = StringBuffer()
      ..writeln(
        '# Generated by the SimCrux riscv-formal check importer'
        '${demo ? ' (demo corpus)' : ''}.',
      )
      ..writeln('# Source: $sourceLabel')
      ..writeln(
        '# One test per bounded proof — SimCrux schedules, times out and '
        'cancels each one',
      )
      ..writeln(
        '# independently, which a single `make -C checks` cannot do.',
      )
      ..writeln('#')
      ..writeln(
        '# This file is yours: read it, diff it, edit it, commit it. '
        'Re-running the importer',
      )
      ..writeln('# overwrites it.');
    if (warnings.isNotEmpty) {
      buf
        ..writeln('#')
        ..writeln('# Import warnings (${warnings.length}):');
      for (final w in warnings) {
        buf.writeln('#   [${w.code}] ${w.message}');
      }
    }

    buf
      ..writeln()
      ..writeln("version: '1'")
      ..writeln()
      ..writeln('defaults:')
      ..writeln('  simulator: ${RiscvConfig.kFormalSimulatorId}')
      ..writeln('  pass_fail:')
      // The detector's config is self-contained and never sees the
      // `riscv:` block. A required pass string that never appears is a
      // FAIL by the detector's documented semantics — never an `unknown`
      // that would fall back to the driver's exit code. The literal is
      // SbyLogReader.kPassMarker, the same constant the driver's parser
      // keys off, so the two halves cannot drift.
      ..writeln('    type: string_match')
      ..writeln("    pass_string: '${SbyLogReader.kPassMarker}'");
    _emitRiscvBlock(buf, defaults, indent: '  ');

    buf
      ..writeln()
      ..writeln('suites:');
    for (final group in orderedGroups) {
      final checks = byGroup[group]!..sort((a, b) => a.name.compareTo(b.name));
      buf
        ..writeln('  ${_yamlSafeKey(group)}:')
        ..writeln(
          '    description: riscv-formal $group proofs (${checks.length}).',
        )
        ..writeln('    tests:');
      for (final check in checks) {
        buf
          ..writeln('      - name: ${_yamlSafeScalar(check.name)}')
          // `top:` is mandatory on every TestSpec; the `.sby` script
          // picks the real top level, so the check name stands in.
          ..writeln('        top: ${_yamlSafeScalar(check.name)}')
          ..writeln('        riscv:')
          ..writeln('          formal:')
          ..writeln(
            '            check: ${_yamlSafeScalar(check.check ?? check.name)}',
          )
          ..writeln('            group: ${_yamlSafeScalar(check.group)}');
        if (check.sbyFile != null) {
          buf.writeln(
            '            sby_file: ${_yamlSafeScalar(check.sbyFile!)}',
          );
        }
        if (check.task != null) {
          buf.writeln('            task: ${_yamlSafeScalar(check.task!)}');
        }
        if (check.demoCase != null) {
          buf.writeln(
            '          demo_case: ${_yamlSafeScalar(check.demoCase!)}',
          );
        }
      }
    }
    return buf.toString();
  }

  void _emitRiscvBlock(
    StringBuffer buf,
    RiscvConfig cfg, {
    required String indent,
  }) {
    buf.writeln('${indent}riscv:');
    final inner = '$indent  ';
    if (cfg.isa != null) {
      buf.writeln('${inner}isa: ${_yamlSafeScalar(cfg.isa!)}');
    }
    if (cfg.mode != null) {
      buf.writeln('${inner}mode: ${cfg.mode!.wireName}');
    }
    final formal = cfg.formal;
    if (formal == null) return;
    buf.writeln('${inner}formal:');
    if (formal.checksDir != null) {
      buf.writeln(
        '$inner  checks_dir: ${_yamlSafeScalar(formal.checksDir!)}',
      );
    }
    if (formal.sbyBinary != null) {
      buf.writeln(
        '$inner  sby_binary: ${_yamlSafeScalar(formal.sbyBinary!)}',
      );
    }
    if (formal.demoOutputs != null) {
      buf.writeln(
        '$inner  demo_outputs: ${_yamlSafeScalar(formal.demoOutputs!)}',
      );
    }
    if ((formal.command ?? const <String>[]).isNotEmpty) {
      buf.writeln('$inner  command:');
      for (final arg in formal.command!) {
        buf.writeln('$inner    - ${_yamlSafeScalar(arg)}');
      }
    }
  }

  String _yamlSafeKey(String key) {
    if (key.isEmpty) return 'imported';
    return key.replaceAll(RegExp('[^A-Za-z0-9_-]'), '_');
  }

  String _yamlSafeScalar(String value) {
    if (value.isEmpty) return "''";
    final needsQuote = RegExp(
      '[:#&*!|>\'"%@`{}\\[\\],?\\s]|^-',
    ).hasMatch(value);
    if (!needsQuote) return value;
    final escaped = value.replaceAll("'", "''");
    return "'$escaped'";
  }
}

class _FormalCheck {
  _FormalCheck({
    required this.name,
    required this.sbyFile,
    required this.group,
    this.task,
    this.check,
    this.demoCase,
  });

  final String name;
  final String? sbyFile;
  final String group;
  final String? task;
  final String? check;
  final String? demoCase;
}
