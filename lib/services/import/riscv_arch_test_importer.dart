// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/riscv_reference_model.dart';
import 'package:simcrux/domain/enums/riscv_run_mode.dart';
import 'package:simcrux/domain/models/riscv_config.dart';
import 'package:simcrux/domain/models/riscv_import_result.dart';

/// Enumerates a `riscv-arch-test` checkout into **one SimCrux `TestSpec` per
/// architectural test**, emitted as inspectable `simcrux.yaml`.
///
/// ## Why an importer and not a driver loop
///
/// The job model has no fan-out: one `TestSpec` yields exactly one
/// `TestExecutionFinished` and exactly one `TestResult`. RISCOF
/// naturally emits *N* results per invocation, so the mismatch has to be
/// resolved **before** the scheduler. Doing it here rather than inside the
/// driver is the `FuseSoCImporter` precedent
/// (`fusesoc_importer.dart`): read an external ecosystem's format, emit a
/// SimCrux config the user can read, diff, edit and commit — rather than
/// hiding the mapping inside a driver where a wrong extension tag or a
/// mis-scanned directory is invisible.
///
/// The user owns the output. Deleting a test, re-tagging its extension, or
/// pinning a per-test timeout is an ordinary YAML edit afterwards.
///
/// ## The layout it reads
///
/// `riscv-arch-test` puts each test at
/// `riscv-test-suite/<arch>/<EXT>/src/<name>.S`, e.g.
/// `riscv-test-suite/rv32i_m/I/src/add-01.S`. The directory two levels above
/// `src/` names the extension, which is how "maps each test to its
/// extension" is satisfied — the tag rides into `riscv.extension`, onto
/// `TestResult.metrics` as `riscv.extension`, and is what the Pro
/// per-extension rollup groups on.
///
/// ## `top:` is synthesized, and that is mandatory
///
/// `top:` is a required `TestSpec` field (the loader rejects a test without
/// one), and an architectural test has no HDL top level. The importer
/// synthesizes the test's base name. An importer that omitted it would
/// produce a config the loader refuses — a real obligation, not an
/// incidental detail.
class RiscvArchTestImporter {
  /// Creates a [RiscvArchTestImporter].
  ///
  /// [listDirectory] and [readFile] are injected so tests drive the importer
  /// against an in-memory tree; production walks the real filesystem.
  RiscvArchTestImporter({
    List<String> Function(String dir)? listDirectory,
    String Function(String path)? readFile,
    bool Function(String path)? directoryExists,
  }) : _listDirectory = listDirectory ?? _defaultListDirectory,
       _readFile = readFile ?? _defaultReadFile,
       _directoryExists = directoryExists ?? _defaultDirectoryExists;

  final List<String> Function(String dir) _listDirectory;
  final String Function(String path) _readFile;
  final bool Function(String path) _directoryExists;

  /// Conventional subdirectory holding the tests inside a checkout.
  static const String kSuiteSubdir = 'riscv-test-suite';

  /// Directory name that marks a test source directory.
  static const String kSrcDirName = 'src';

  static List<String> _defaultListDirectory(String dir) {
    final directory = Directory(dir);
    if (!directory.existsSync()) return const <String>[];
    return directory.listSync().map((e) => e.path).toList(growable: false)
      ..sort();
  }

  static String _defaultReadFile(String path) => File(path).readAsStringSync();

  static bool _defaultDirectoryExists(String path) =>
      Directory(path).existsSync();

  // ── the real suite ─────────────────────────────────────────────────

  /// Enumerates the `riscv-arch-test` checkout rooted at [suitePath].
  ///
  /// [extensions], when non-empty, restricts the import to those extension
  /// directories (case-insensitively); otherwise everything found is
  /// imported. [defaults] supplies the shared `riscv:` plumbing —
  /// reference model, toolchain, target command, compile settings — that
  /// lands once under `defaults.riscv` and is inherited by every test.
  ///
  /// Throws [RiscvImportException] when the path is not a suite, or when the
  /// scan produced no tests at all (which is always a wrong-path mistake
  /// rather than an empty-but-valid suite).
  RiscvImportResult importSuite({
    required String suitePath,
    RiscvConfig defaults = const RiscvConfig(),
    List<String> extensions = const <String>[],
  }) {
    final warnings = <RiscvImportWarning>[];
    final absSuite = p.normalize(p.absolute(suitePath));
    if (!_directoryExists(absSuite)) {
      throw RiscvImportException(
        path: absSuite,
        message: 'Not a directory — point at a `riscv-arch-test` checkout.',
      );
    }
    // A checkout normally has a `riscv-test-suite/` subdirectory; accept a
    // path that already points inside it too.
    final withSubdir = p.join(absSuite, kSuiteSubdir);
    final scanRoot = _directoryExists(withSubdir) ? withSubdir : absSuite;
    if (scanRoot == absSuite) {
      warnings.add(
        const RiscvImportWarning(
          code: 'no_suite_subdir',
          message:
              'No `$kSuiteSubdir/` subdirectory found; scanning the given '
              'path directly. Check the emitted `riscv.test` paths look '
              'right before committing.',
        ),
      );
    }

    final wanted = extensions.map((e) => e.toLowerCase()).toSet();
    final byExtension = <String, List<_ArchTest>>{};
    for (final srcDir in _findSrcDirs(scanRoot)) {
      final extension = p.basename(p.dirname(srcDir));
      if (wanted.isNotEmpty && !wanted.contains(extension.toLowerCase())) {
        continue;
      }
      for (final file in _listDirectory(srcDir)) {
        if (p.extension(file).toUpperCase() != '.S') continue;
        final name = p.basenameWithoutExtension(file);
        byExtension
            .putIfAbsent(extension, () => <_ArchTest>[])
            .add(
              _ArchTest(
                name: name,
                // Relative to `arch_test.suite_path`, which the emitted
                // config pins to the scanned root — so the driver's
                // resolution yields an absolute path with no cwd
                // dependence.
                //
                // Emitted with POSIX separators regardless of host. The file
                // this lands in tells the user to "read it, diff it, edit it,
                // commit it", so it is a portable artifact: a config generated
                // on Windows carrying `rv32i_m\I\src\add-01.S` would not
                // resolve for a colleague on Linux, and would show up as a
                // whole-file diff whenever the two regenerated it. `/` is the
                // config convention and works on all three platforms —
                // `p.join` and `File` both accept it on Windows.
                relativePath: p
                    .split(p.relative(file, from: scanRoot))
                    .join('/'),
                extension: extension,
              ),
            );
      }
    }
    if (byExtension.isEmpty) {
      throw RiscvImportException(
        path: scanRoot,
        message:
            'No architectural tests found. Expected '
            '`<extension>/$kSrcDirName/<name>.S` beneath this path'
            '${extensions.isEmpty ? '' : ' for extensions ${extensions.join(', ')}'}.',
      );
    }

    final orderedExtensions = byExtension.keys.toList()..sort();
    final effectiveDefaults = defaults.copyWith(
      archTest: (defaults.archTest ?? const RiscvArchTestConfig()).mergeOnto(
        RiscvArchTestConfig(suitePath: scanRoot),
      ),
      extensions: defaults.extensions ?? orderedExtensions,
    );
    if ((effectiveDefaults.target?.command ?? const <String>[]).isEmpty &&
        effectiveDefaults.effectiveMode == RiscvRunMode.normal) {
      warnings.add(
        const RiscvImportWarning(
          code: 'missing_target_command',
          message:
              'No `riscv.target.command` was supplied, so the emitted config '
              'will not load until you fill it in — it is the command that '
              'runs your DUT for one test. Use the `{elf}` and `{signature}` '
              'placeholders.',
        ),
      );
    }

    final yaml = _emit(
      sourceLabel: scanRoot,
      defaults: effectiveDefaults,
      byExtension: byExtension,
      orderedExtensions: orderedExtensions,
      warnings: warnings,
    );
    return RiscvImportResult(
      simcruxYaml: yaml,
      suggestedOutputFilename: 'simcrux.yaml',
      testCount: byExtension.values.fold(0, (a, b) => a + b.length),
      extensions: orderedExtensions,
      warnings: warnings,
    );
  }

  // ── demo mode ──────────────────────────────────────────────────────

  /// Enumerates a committed pre-captured signature corpus into the same
  /// shape, for [RiscvRunMode.demo].
  ///
  /// **Consumes the `golden_compare` corpus as-is** rather than authoring a
  /// second fixture set: each immediate subdirectory of [demoSignaturesPath] is
  /// one case, and its `case.json` supplies the dump filenames the driver
  /// stages. An `extension` key in `case.json` tags the case; absent, the
  /// case is tagged [fallbackExtension] — the `golden_compare` corpus carries no extension
  /// key, which is fine because those cases exercise *comparison* semantics
  /// rather than ISA coverage.
  ///
  /// This is how CI tests the driver and how the dashboard is demoed
  /// offline on a laptop: no cross-compiler, no reference model, no
  /// network, and the identical driver code path.
  RiscvImportResult importDemo({
    required String demoSignaturesPath,
    RiscvConfig defaults = const RiscvConfig(),
    String fallbackExtension = 'I',
  }) {
    final warnings = <RiscvImportWarning>[];
    final absRoot = p.normalize(p.absolute(demoSignaturesPath));
    if (!_directoryExists(absRoot)) {
      throw RiscvImportException(
        path: absRoot,
        message:
            'Not a directory — point at a corpus of pre-captured signature '
            'pairs (one subdirectory per case).',
      );
    }
    final byExtension = <String, List<_ArchTest>>{};
    for (final entry in _listDirectory(absRoot)) {
      if (!_directoryExists(entry)) continue;
      final caseName = p.basename(entry);
      final extension = _demoCaseExtension(entry) ?? fallbackExtension;
      byExtension
          .putIfAbsent(extension, () => <_ArchTest>[])
          .add(
            _ArchTest(
              name: caseName,
              relativePath: caseName,
              extension: extension,
              demoCase: caseName,
            ),
          );
    }
    if (byExtension.isEmpty) {
      throw RiscvImportException(
        path: absRoot,
        message: 'No case subdirectories found under this path.',
      );
    }

    final orderedExtensions = byExtension.keys.toList()..sort();
    final effectiveDefaults = defaults.copyWith(
      mode: RiscvRunMode.demo,
      demoSignatures: absRoot,
      extensions: defaults.extensions ?? orderedExtensions,
    );
    final yaml = _emit(
      sourceLabel: absRoot,
      defaults: effectiveDefaults,
      byExtension: byExtension,
      orderedExtensions: orderedExtensions,
      warnings: warnings,
      demo: true,
    );
    return RiscvImportResult(
      simcruxYaml: yaml,
      suggestedOutputFilename: 'simcrux.yaml',
      testCount: byExtension.values.fold(0, (a, b) => a + b.length),
      extensions: orderedExtensions,
      warnings: warnings,
    );
  }

  String? _demoCaseExtension(String caseDir) {
    try {
      final decoded = jsonDecode(_readFile(p.join(caseDir, 'case.json')));
      if (decoded is! Map<String, Object?>) return null;
      final extension = decoded['extension'];
      if (extension is String && extension.isNotEmpty) return extension;
      return null;
    } on Object {
      return null;
    }
  }

  // ── scanning ───────────────────────────────────────────────────────

  /// Depth-first walk collecting every directory literally named `src`.
  List<String> _findSrcDirs(String root) {
    final found = <String>[];
    void walk(String dir, int depth) {
      // riscv-arch-test nests <arch>/<ext>/src; a small depth cap keeps a
      // mistyped path (a home directory, say) from walking the world.
      if (depth > 6) return;
      for (final entry in _listDirectory(dir)) {
        if (!_directoryExists(entry)) continue;
        if (p.basename(entry) == kSrcDirName) {
          found.add(entry);
          continue;
        }
        walk(entry, depth + 1);
      }
    }

    walk(root, 0);
    found.sort();
    return found;
  }

  // ── emission ───────────────────────────────────────────────────────

  String _emit({
    required String sourceLabel,
    required RiscvConfig defaults,
    required Map<String, List<_ArchTest>> byExtension,
    required List<String> orderedExtensions,
    required List<RiscvImportWarning> warnings,
    bool demo = false,
  }) {
    final buf = StringBuffer()
      ..writeln(
        '# Generated by the SimCrux RISC-V arch-test importer'
        '${demo ? ' (demo corpus)' : ''}.',
      )
      ..writeln('# Source: $sourceLabel')
      ..writeln(
        '# One test per architectural test — SimCrux schedules, times out '
        'and cancels each one',
      )
      ..writeln(
        '# independently, which a single whole-suite RISCOF invocation '
        'cannot do.',
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
      ..writeln('  simulator: ${RiscvConfig.kSimulatorId}')
      ..writeln('  pass_fail:')
      // The detector's config is self-contained and never sees the `riscv:`
      // block. With `profile: riscv_signature` and no explicit paths it
      // resolves to `signature.dut.sig` / `signature.ref.sig` — exactly
      // what the driver writes. That shared convention is what keeps the
      // two halves in agreement.
      ..writeln('    type: golden_compare')
      ..writeln('    profile: riscv_signature');
    _emitRiscvBlock(buf, defaults, indent: '  ');

    buf
      ..writeln()
      ..writeln('suites:');
    for (final extension in orderedExtensions) {
      final tests = byExtension[extension]!
        ..sort((a, b) => a.name.compareTo(b.name));
      buf
        ..writeln('  ${_yamlSafeKey(extension)}:')
        ..writeln(
          '    description: RISC-V $extension architectural tests '
          '(${tests.length}).',
        )
        ..writeln('    tests:');
      for (final test in tests) {
        buf
          ..writeln('      - name: ${_yamlSafeScalar(test.name)}')
          // `top:` is mandatory on every TestSpec and an architectural test
          // has no HDL top level, so the base name stands in.
          ..writeln('        top: ${_yamlSafeScalar(test.name)}')
          ..writeln('        riscv:')
          ..writeln('          test: ${_yamlSafeScalar(test.relativePath)}')
          ..writeln(
            '          extension: ${_yamlSafeScalar(test.extension)}',
          );
        if (test.demoCase != null) {
          buf.writeln(
            '          demo_case: ${_yamlSafeScalar(test.demoCase!)}',
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
    if (cfg.demoSignatures != null) {
      buf.writeln(
        '${inner}demo_signatures: ${_yamlSafeScalar(cfg.demoSignatures!)}',
      );
    }
    final reference = cfg.reference;
    if (reference != null &&
        (reference.model != null || reference.path != null)) {
      buf.writeln('${inner}reference:');
      if (reference.model != null) {
        buf.writeln('$inner  model: ${reference.model!.wireName}');
      } else {
        buf.writeln(
          '$inner  model: ${RiscvReferenceModel.spike.wireName}',
        );
      }
      if (reference.path != null) {
        buf.writeln('$inner  path: ${_yamlSafeScalar(reference.path!)}');
      }
    }
    final archTest = cfg.archTest;
    if (archTest != null &&
        (archTest.suitePath != null || archTest.revision != null)) {
      buf.writeln('${inner}arch_test:');
      if (archTest.suitePath != null) {
        buf.writeln(
          '$inner  suite_path: ${_yamlSafeScalar(archTest.suitePath!)}',
        );
      }
      if (archTest.revision != null) {
        buf.writeln(
          '$inner  revision: ${_yamlSafeScalar(archTest.revision!)}',
        );
      }
    }
    final toolchain = cfg.toolchain;
    if (toolchain != null &&
        (toolchain.prefix != null || toolchain.path != null)) {
      buf.writeln('${inner}toolchain:');
      if (toolchain.prefix != null) {
        buf.writeln('$inner  prefix: ${_yamlSafeScalar(toolchain.prefix!)}');
      }
      if (toolchain.path != null) {
        buf.writeln('$inner  path: ${_yamlSafeScalar(toolchain.path!)}');
      }
    }
    final target = cfg.target;
    if (target != null && (target.command ?? const <String>[]).isNotEmpty) {
      buf
        ..writeln('${inner}target:')
        ..writeln('$inner  command:');
      for (final arg in target.command!) {
        buf.writeln('$inner    - ${_yamlSafeScalar(arg)}');
      }
    }
    final compile = cfg.compile;
    if (compile != null) {
      final hasAny =
          compile.linkScript != null ||
          (compile.includeDirs ?? const <String>[]).isNotEmpty ||
          (compile.extraArgs ?? const <String>[]).isNotEmpty;
      if (hasAny) {
        buf.writeln('${inner}compile:');
        if (compile.linkScript != null) {
          buf.writeln(
            '$inner  link_script: ${_yamlSafeScalar(compile.linkScript!)}',
          );
        }
        if ((compile.includeDirs ?? const <String>[]).isNotEmpty) {
          buf.writeln('$inner  include_dirs:');
          for (final dir in compile.includeDirs!) {
            buf.writeln('$inner    - ${_yamlSafeScalar(dir)}');
          }
        }
        if ((compile.extraArgs ?? const <String>[]).isNotEmpty) {
          buf.writeln('$inner  extra_args:');
          for (final arg in compile.extraArgs!) {
            buf.writeln('$inner    - ${_yamlSafeScalar(arg)}');
          }
        }
      }
    }
    final signature = cfg.signature;
    if (signature != null && signature.wordSize != null) {
      buf
        ..writeln('${inner}signature:')
        ..writeln('$inner  word_size: ${signature.wordSize}');
    }
    final extensions = cfg.extensions;
    if (extensions != null && extensions.isNotEmpty) {
      buf.writeln(
        '${inner}extensions: [${extensions.map(_yamlSafeScalar).join(', ')}]',
      );
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

class _ArchTest {
  _ArchTest({
    required this.name,
    required this.relativePath,
    required this.extension,
    this.demoCase,
  });

  final String name;
  final String relativePath;
  final String extension;
  final String? demoCase;
}
