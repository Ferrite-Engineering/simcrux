// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/riscv_import_kind.dart';
import 'package:simcrux/domain/enums/riscv_reference_model.dart';
import 'package:simcrux/domain/enums/riscv_run_mode.dart';
import 'package:simcrux/domain/models/riscv_config.dart';
import 'package:simcrux/domain/models/riscv_import_result.dart';
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/import/riscv_arch_test_importer.dart';
import 'package:simcrux/services/import/riscv_formal_check_importer.dart';

/// A line of emitted YAML that sets a project-tooling key the importers can
/// write: a `command:` list, `sby_binary:`, or the toolchain / reference
/// `prefix:` and `path:`. Anchored at the key, so `suite_path:` is not one.
final RegExp _namesGatedTooling = RegExp(
  r'^\s+(command|sby_binary|prefix|path|binary):',
  multiLine: true,
);

/// Thrown for a usage-level problem with a `simcrux import-riscv-…`
/// invocation (bad flag, wrong positional count, unparseable value).
///
/// Distinct from [RiscvImportException], which the importers throw when the
/// *input tree* is wrong. The bootstrap prints either verbatim and exits 2;
/// keeping them separate is what lets a test assert which of the two kinds
/// of mistake the user made.
class RiscvImportCliException implements Exception {
  /// Creates a [RiscvImportCliException].
  const RiscvImportCliException(this.message);

  /// Human-readable description, already prefixed for direct printing.
  final String message;

  @override
  String toString() => message;
}

/// What [RiscvImportCli.run] wrote.
class RiscvImportCliResult {
  /// Creates a [RiscvImportCliResult].
  const RiscvImportCliResult({
    required this.outputPath,
    required this.testCount,
    required this.groups,
    required this.warnings,
  });

  /// Absolute path of the written `simcrux.yaml`.
  final String outputPath;

  /// How many `TestSpec`s the emitted file declares — one per
  /// architectural test or per bounded proof.
  final int testCount;

  /// Extension tags (arch-test) or property groups (formal), in emission
  /// order. One suite per entry.
  final List<String> groups;

  /// Non-fatal issues, also echoed into the emitted YAML's header comment.
  final List<RiscvImportWarning> warnings;
}

/// The `simcrux import-riscv-arch-test` / `simcrux import-riscv-formal`
/// sub-commands: the CLI half of the two RISC-V importers' entry point.
///
/// ## Why a sub-command and not another `--import-…` option
///
/// `--import-fusesoc <core-file>` is a single-value option because a FuseSoC
/// import takes exactly one input and nothing else. Neither RISC-V import is
/// that shape. `riscv.target.command` — the command that runs the user's DUT
/// for one architectural test — is **required** by the loader in
/// `mode: normal` and cannot be derived from a checkout, so the arch-test
/// import needs at least one more argument before it can emit a config that
/// loads. Add the extension / group filters (nobody imports all of
/// `riscv-arch-test` on the first try), the reference model, and the
/// toolchain prefix, and the invocation needs its own flag namespace.
///
/// `export-dashboard` already established that shape: the sub-command word
/// is matched in [CliArgParser.parse] before the primary option parser runs,
/// and everything after it is forwarded verbatim to a handler that owns its
/// own [ArgParser]. This is the same handler, for the same reason.
///
/// ## Where the output goes
///
/// `simcrux.yaml` in the **current working directory** unless `--out` says
/// otherwise. Deliberately not inside the scanned tree: a `riscv-arch-test`
/// or riscv-formal checkout is somebody else's git repository, and writing a
/// generated file into it would show up as an untracked file in their
/// `git status` (or fail outright on a read-only checkout).
///
/// Everything the emitted config points *back* at — `arch_test.suite_path`,
/// `formal.checks_dir`, `demo_signatures`, `formal.demo_outputs` — is
/// absolutized by the importers, so the emitted file resolves from wherever
/// it is opened rather than from wherever the importer ran.
class RiscvImportCli {
  /// Creates a [RiscvImportCli].
  ///
  /// [writeText] and [stdoutWriter] are injected so tests drive the whole
  /// command without touching the disk or the console; production writes
  /// real files and prints real lines.
  RiscvImportCli({
    Future<void> Function(String path, String contents)? writeText,
    void Function(String line)? stdoutWriter,
    RiscvArchTestImporter? archImporter,
    RiscvFormalCheckImporter? formalImporter,
  }) : _writeText = writeText ?? _defaultWriteText,
       _stdoutWriter = stdoutWriter ?? _defaultStdout,
       _archImporter = archImporter ?? RiscvArchTestImporter(),
       _formalImporter = formalImporter ?? RiscvFormalCheckImporter();

  final Future<void> Function(String path, String contents) _writeText;
  final void Function(String line) _stdoutWriter;
  final RiscvArchTestImporter _archImporter;
  final RiscvFormalCheckImporter _formalImporter;

  static Future<void> _defaultWriteText(String path, String contents) =>
      File(path).writeAsString(contents);

  // The CLI's own status output is stdout by contract, same as
  // `export-dashboard`'s summary line and `--import-fusesoc`'s.
  // ignore: avoid_print
  static void _defaultStdout(String line) => print(line);

  /// Usage block for [kind], for `--help` and for error messages.
  static String usageFor(RiscvImportKind kind) =>
      '${_headerFor(kind)}\n\n${_parserFor(kind).usage}';

  /// Runs the [kind] import over [args] (everything after the sub-command
  /// word).
  ///
  /// Throws [RiscvImportCliException] for a usage mistake and
  /// [RiscvImportException] when the named tree is not the thing it claims
  /// to be.
  Future<RiscvImportCliResult> run(
    RiscvImportKind kind,
    List<String> args,
  ) async {
    final parser = _parserFor(kind);
    final ArgResults parsed;
    try {
      parsed = parser.parse(args);
    } on FormatException catch (e) {
      throw RiscvImportCliException(
        'simcrux ${kind.subcommand}: ${e.message}\n\n${usageFor(kind)}',
      );
    }
    if (parsed.flag('help')) {
      _stdoutWriter(usageFor(kind));
      return const RiscvImportCliResult(
        outputPath: '',
        testCount: 0,
        groups: <String>[],
        warnings: <RiscvImportWarning>[],
      );
    }
    if (parsed.rest.length != 1) {
      throw RiscvImportCliException(
        'simcrux ${kind.subcommand} expects exactly one positional argument '
        '(${_positionalNameFor(kind)}), got ${parsed.rest.length}.'
        '\n\n${usageFor(kind)}',
      );
    }

    final mode = _readMode(kind, parsed);
    final inputPath = parsed.rest.single;
    final result = switch (kind) {
      RiscvImportKind.archTest => _runArchTest(parsed, inputPath, mode),
      RiscvImportKind.formal => _runFormal(parsed, inputPath, mode),
    };

    final outPath = p.normalize(
      p.absolute(
        parsed.option('out') ??
            p.join(Directory.current.path, result.suggestedOutputFilename),
      ),
    );
    await _writeText(outPath, result.simcruxYaml);

    final unit = switch (kind) {
      RiscvImportKind.archTest => 'extension(s)',
      RiscvImportKind.formal => 'group(s)',
    };
    _stdoutWriter(
      'simcrux: wrote $outPath — ${result.testCount} test(s) across '
      '${result.extensions.length} $unit (${result.extensions.join(', ')})',
    );
    for (final warning in result.warnings) {
      _stdoutWriter('simcrux: [${warning.code}] ${warning.message}');
    }
    // The emitted file can carry project-defined tooling: `target.command`,
    // a `formal.command`, or an executable path (`--toolchain-path`,
    // `--toolchain-prefix`, `--reference-path`, `--sby-binary`). The loader
    // refuses or ignores those by default no matter who wrote the file, so
    // say up front how to let this one run rather than letting the user hit
    // a load error or a silently-ignored path with no context.
    if (_namesGatedTooling.hasMatch(result.simcruxYaml)) {
      _stdoutWriter(
        'simcrux: this config names a program for SimCrux to run, which a '
        'project file may not do until you allow it. '
        '$kProjectToolingRemedy',
      );
    }

    return RiscvImportCliResult(
      outputPath: outPath,
      testCount: result.testCount,
      groups: result.extensions,
      warnings: result.warnings,
    );
  }

  // ── the two importers ──────────────────────────────────────────────

  RiscvImportResult _runArchTest(
    ArgResults parsed,
    String inputPath,
    RiscvRunMode mode,
  ) {
    final defaults = RiscvConfig(
      isa: parsed.option('isa'),
      target: _targetFrom(parsed),
      toolchain: _toolchainFrom(parsed),
      reference: _referenceFrom(parsed),
      signature: _signatureFrom(parsed),
    );
    if (mode == RiscvRunMode.demo) {
      return _archImporter.importDemo(
        demoSignaturesPath: inputPath,
        defaults: defaults,
      );
    }
    return _archImporter.importSuite(
      suitePath: inputPath,
      defaults: defaults.copyWith(mode: RiscvRunMode.normal),
      extensions: _csv(parsed.option('extensions')),
    );
  }

  RiscvImportResult _runFormal(
    ArgResults parsed,
    String inputPath,
    RiscvRunMode mode,
  ) {
    final sbyBinary = parsed.option('sby-binary');
    final defaults = RiscvConfig(
      isa: parsed.option('isa'),
      formal: sbyBinary == null
          ? null
          : RiscvFormalConfig(sbyBinary: sbyBinary),
    );
    if (mode == RiscvRunMode.demo) {
      return _formalImporter.importDemo(
        demoOutputsPath: inputPath,
        defaults: defaults,
      );
    }
    return _formalImporter.importChecks(
      checksPath: inputPath,
      defaults: defaults.copyWith(mode: RiscvRunMode.normal),
      groups: _csv(parsed.option('groups')),
    );
  }

  // ── option → config mapping ────────────────────────────────────────

  RiscvRunMode _readMode(RiscvImportKind kind, ArgResults parsed) {
    final raw = parsed.option('mode');
    if (raw == null) return RiscvRunMode.normal;
    final parsedMode = RiscvRunMode.fromWireName(raw);
    if (parsedMode == null || parsedMode == RiscvRunMode.riscofPassthrough) {
      throw RiscvImportCliException(
        'simcrux ${kind.subcommand}: --mode must be `normal` or `demo` (got '
        '"$raw"). `riscof_passthrough` is a run mode you write into the '
        'config yourself; there is nothing for an importer to enumerate '
        'under it.\n\n${usageFor(kind)}',
      );
    }
    return parsedMode;
  }

  RiscvTargetConfig? _targetFrom(ArgResults parsed) {
    final raw = parsed.option('target-command');
    if (raw == null) return null;
    final argv = splitCommandLine(raw);
    if (argv.isEmpty) {
      throw RiscvImportCliException(
        'simcrux ${RiscvImportKind.archTest.subcommand}: --target-command '
        'was empty. It is the command that runs YOUR core for one '
        'architectural test, e.g. '
        "--target-command './my_core --elf {elf} --signature {signature}'",
      );
    }
    return RiscvTargetConfig(command: argv);
  }

  RiscvToolchainConfig? _toolchainFrom(ArgResults parsed) {
    final prefix = parsed.option('toolchain-prefix');
    final path = parsed.option('toolchain-path');
    if (prefix == null && path == null) return null;
    return RiscvToolchainConfig(prefix: prefix, path: path);
  }

  RiscvReferenceConfig? _referenceFrom(ArgResults parsed) {
    final rawModel = parsed.option('reference-model');
    final path = parsed.option('reference-path');
    if (rawModel == null && path == null) return null;
    RiscvReferenceModel? model;
    if (rawModel != null) {
      model = RiscvReferenceModel.fromWireName(rawModel);
      if (model == null) {
        throw RiscvImportCliException(
          'simcrux ${RiscvImportKind.archTest.subcommand}: '
          '--reference-model must be one of '
          '${RiscvReferenceModel.wireNames.join(', ')} (got "$rawModel").',
        );
      }
    }
    return RiscvReferenceConfig(model: model, path: path);
  }

  RiscvSignatureConfig? _signatureFrom(ArgResults parsed) {
    final raw = parsed.option('word-size');
    if (raw == null) return null;
    final wordSize = int.tryParse(raw);
    if (wordSize == null || wordSize <= 0) {
      throw RiscvImportCliException(
        'simcrux ${RiscvImportKind.archTest.subcommand}: --word-size expects '
        'a positive integer number of bytes per signature word, got "$raw".',
      );
    }
    return RiscvSignatureConfig(wordSize: wordSize);
  }

  static List<String> _csv(String? raw) {
    if (raw == null) return const <String>[];
    return raw
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }

  // ── parsers ────────────────────────────────────────────────────────

  static String _positionalNameFor(RiscvImportKind kind) => switch (kind) {
    RiscvImportKind.archTest => 'the riscv-arch-test checkout',
    RiscvImportKind.formal => 'the riscv-formal `checks/` directory',
  };

  static String _headerFor(RiscvImportKind kind) => switch (kind) {
    RiscvImportKind.archTest =>
      'Usage: simcrux ${kind.subcommand} <suite-path> [options]\n\n'
          'Enumerates a riscv-arch-test checkout into one SimCrux test per '
          'architectural\ntest and writes an inspectable simcrux.yaml you '
          'own. Nothing is run.',
    RiscvImportKind.formal =>
      'Usage: simcrux ${kind.subcommand} <checks-path> [options]\n\n'
          'Enumerates the .sby jobs written by riscv-formal genchecks.py '
          'into one SimCrux\ntest per bounded proof and writes an '
          'inspectable simcrux.yaml you own.\nNothing is run.',
  };

  static ArgParser _parserFor(RiscvImportKind kind) {
    final parser = ArgParser()
      ..addOption(
        'out',
        abbr: 'o',
        help:
            'Where to write the generated project file. Defaults to '
            './simcrux.yaml — never inside the scanned checkout, which is '
            "somebody else's git repository.",
        valueHelp: 'path',
      )
      ..addOption(
        'mode',
        help:
            'normal (default) enumerates a real checkout; demo enumerates '
            'a committed corpus of pre-captured outputs and emits '
            '`mode: demo`, which spawns nothing.',
        // Deliberately NOT `allowed:`. `args`'s own rejection message lists
        // the permitted values and stops there; a user who typed
        // `riscof_passthrough` needs to be told *why* it is not an import
        // mode, which `_readMode` does.
        valueHelp: 'normal|demo',
      )
      ..addOption(
        'isa',
        help:
            'ISA string recorded once under defaults.riscv.isa and echoed '
            'onto every result (e.g. rv32imc_zicsr_zifencei).',
        valueHelp: 'string',
      );
    if (kind == RiscvImportKind.archTest) {
      parser
        ..addOption(
          'extensions',
          help:
              'Comma-separated extension directories to import '
              '(e.g. I,M,C). Case-insensitive. Default: everything found.',
          valueHelp: 'I,M,C',
        )
        ..addOption(
          'target-command',
          help:
              'REQUIRED for a config that loads in --mode normal: the '
              'command that runs YOUR core for one architectural test. Use '
              'the {elf} and {signature} placeholders. Quoted as one '
              'string and split like a shell would split it, e.g. '
              "'./my_core --elf {elf} --signature {signature}'.",
          valueHelp: 'command',
        )
        ..addOption(
          'toolchain-prefix',
          help:
              'Cross-toolchain prefix used to build each test '
              '(e.g. riscv64-unknown-elf-).',
          valueHelp: 'prefix',
        )
        ..addOption(
          'toolchain-path',
          help: 'Directory containing the cross-toolchain binaries.',
          valueHelp: 'dir',
        )
        ..addOption(
          'reference-model',
          help:
              'Reference model that produces the golden signature: '
              '${RiscvReferenceModel.wireNames.join(', ')}.',
          // Not `allowed:` either — `_referenceFrom` owns the rejection so
          // the enum stays the single source of the permitted set.
          valueHelp: 'model',
        )
        ..addOption(
          'reference-path',
          help: 'Path to the reference-model binary.',
          valueHelp: 'path',
        )
        ..addOption(
          'word-size',
          help:
              'Bytes per signature word. It is what turns the comparison '
              'word offset into the byte offset of the divergent '
              'instruction.',
          valueHelp: 'bytes',
        );
    } else {
      parser
        ..addOption(
          'groups',
          help:
              'Comma-separated property groups to import '
              '(e.g. insn,reg,pc_fwd). Case-insensitive. Default: '
              'everything found.',
          valueHelp: 'insn,reg',
        )
        ..addOption(
          'sby-binary',
          help: 'Path to the SymbiYosys binary, when `sby` is not on PATH.',
          valueHelp: 'path',
        );
    }
    return parser..addFlag(
      'help',
      abbr: 'h',
      help: 'Show this usage and exit.',
      negatable: false,
    );
  }
}

/// Splits [input] into argv elements the way a POSIX shell would, honoring
/// single quotes, double quotes and backslash escapes.
///
/// Exists because `riscv.target.command` is a **list**, and the natural way
/// to type a list on a command line is one quoted string. The alternative —
/// a repeated `--target-command` per argv element — turns a five-word
/// command into five flags, which nobody types correctly the first time.
///
/// Placeholders (`{elf}`, `{signature}`) survive verbatim: braces are not
/// special here, and the driver expands them at spawn time.
List<String> splitCommandLine(String input) {
  final argv = <String>[];
  final current = StringBuffer();
  var hasToken = false;
  String? quote;
  for (var i = 0; i < input.length; i++) {
    final ch = input[i];
    if (quote != null) {
      if (ch == quote) {
        quote = null;
      } else if (ch == r'\' && quote == '"' && i + 1 < input.length) {
        current.write(input[++i]);
      } else {
        current.write(ch);
      }
      continue;
    }
    if (ch == "'" || ch == '"') {
      quote = ch;
      hasToken = true;
      continue;
    }
    if (ch == r'\' && i + 1 < input.length) {
      current.write(input[++i]);
      hasToken = true;
      continue;
    }
    if (ch == ' ' || ch == '\t' || ch == '\n') {
      if (hasToken) {
        argv.add(current.toString());
        current.clear();
        hasToken = false;
      }
      continue;
    }
    current.write(ch);
    hasToken = true;
  }
  if (hasToken) argv.add(current.toString());
  return argv;
}
