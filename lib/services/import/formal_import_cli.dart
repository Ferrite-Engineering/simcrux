// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/formal_import_kind.dart';
import 'package:simcrux/domain/models/formal_import_result.dart';
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/import/eqy_project_importer.dart';
import 'package:simcrux/services/import/sby_project_importer.dart';

/// Thrown for a usage-level problem with a `simcrux import-sby` or
/// `simcrux import-eqy` invocation:
/// an unknown flag, a wrong positional count. The bootstrap prints it to
/// stderr and exits 2, SimCrux's grandfathered usage code, which every
/// `simcrux import-*` sub-command shares.
class FormalImportCliException implements Exception {
  /// Creates a [FormalImportCliException].
  const FormalImportCliException(this.message);

  /// Human-readable description, already prefixed for direct printing.
  final String message;

  @override
  String toString() => message;
}

/// What [FormalImportCli.run] did.
class FormalImportCliResult {
  /// Creates a result.
  const FormalImportCliResult({
    required this.outputPath,
    required this.testCount,
    required this.jobs,
    required this.warnings,
    this.helpShown = false,
  });

  /// The answer to `-h` / `--help`: usage printed, nothing read or written.
  static const FormalImportCliResult help = FormalImportCliResult(
    outputPath: '',
    testCount: 0,
    jobs: <String>[],
    warnings: <FormalImportWarning>[],
    helpShown: true,
  );

  /// Absolute path of the written `simcrux.yaml`; empty for [help].
  final String outputPath;

  /// How many tests the written file declares: one per task.
  final int testCount;

  /// The job files imported, by basename.
  final List<String> jobs;

  /// Non-fatal findings, also echoed into the written file's header.
  final List<FormalImportWarning> warnings;

  /// Whether this was the help answer.
  final bool helpShown;
}

/// The `simcrux import-sby` and `simcrux import-eqy` sub-commands: the
/// command-line doors onto [SbyProjectImporter] and [EqyProjectImporter].
///
/// Same shape as `import-riscv-formal` beside it: the sub-command word is
/// matched before the primary option parser and everything after it is this
/// handler's, with its own [ArgParser].
///
/// - `-h` / `--help` prints the usage to stdout and returns before any file
///   or engine is touched, even when other arguments are wrong.
/// - An unknown flag or a wrong positional count is a usage error
///   ([FormalImportCliException]); the caller exits 2.
/// - The summary line (the path written) is stdout, the command's output;
///   warnings and the project-tooling note are diagnostics, so stderr.
/// - The file goes to `./simcrux.yaml` unless `--out` says otherwise.
class FormalImportCli {
  /// Creates a [FormalImportCli]. The writers are injected so tests run the
  /// whole command without touching the disk or the console.
  FormalImportCli({
    Future<void> Function(String path, String contents)? writeText,
    void Function(String line)? stdoutWriter,
    void Function(String line)? stderrWriter,
    SbyProjectImporter? sbyImporter,
    EqyProjectImporter? eqyImporter,
    String Function()? currentDirectory,
  }) : _writeText = writeText ?? _defaultWriteText,
       _stdoutWriter = stdoutWriter ?? _defaultStdout,
       _stderrWriter = stderrWriter ?? _defaultStderr,
       _sbyImporter = sbyImporter ?? SbyProjectImporter(),
       _eqyImporter = eqyImporter ?? EqyProjectImporter(),
       _currentDirectory = currentDirectory ?? _defaultCurrentDirectory;

  final Future<void> Function(String path, String contents) _writeText;
  final void Function(String line) _stdoutWriter;
  final void Function(String line) _stderrWriter;
  final SbyProjectImporter _sbyImporter;
  final EqyProjectImporter _eqyImporter;
  final String Function() _currentDirectory;

  static Future<void> _defaultWriteText(String path, String contents) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(contents);
  }

  // The command's own output is stdout by contract, as `import-riscv-formal`
  // and `export-dashboard` print theirs.
  // ignore: avoid_print
  static void _defaultStdout(String line) => print(line);

  static void _defaultStderr(String line) => stderr.writeln(line);

  static String _defaultCurrentDirectory() => Directory.current.path;

  /// Usage block for [kind], for `--help` and for error messages.
  static String usageFor(FormalImportKind kind) =>
      '${_headerFor(kind)}\n\n${_parserFor(kind).usage}';

  /// Whether [args] asks for help, before any `--` that ends the options.
  static bool _asksForHelp(List<String> args) {
    for (final arg in args) {
      if (arg == '--') return false;
      if (arg == '-h' || arg == '--help') return true;
    }
    return false;
  }

  /// Runs the [kind] import over [args] (everything after the sub-command
  /// word).
  ///
  /// Throws [FormalImportCliException] for a usage mistake and
  /// [FormalImportException] when the named input holds nothing to import.
  Future<FormalImportCliResult> run(
    FormalImportKind kind,
    List<String> args,
  ) async {
    // Help first: before the parser can refuse a sibling flag, and before
    // any file is read.
    if (_asksForHelp(args)) {
      _stdoutWriter(usageFor(kind));
      return FormalImportCliResult.help;
    }
    final parser = _parserFor(kind);
    final ArgResults parsed;
    try {
      parsed = parser.parse(args);
    } on FormatException catch (e) {
      throw FormalImportCliException(
        'simcrux ${kind.subcommand}: ${e.message}\n\n${usageFor(kind)}',
      );
    }
    if (parsed.rest.length != 1) {
      final expected = switch (kind) {
        FormalImportKind.sby => 'a .sby file or a directory holding them',
        FormalImportKind.eqy => 'a .eqy file',
      };
      throw FormalImportCliException(
        'simcrux ${kind.subcommand} expects exactly one positional argument '
        '($expected), got ${parsed.rest.length}.\n\n${usageFor(kind)}',
      );
    }

    final cwd = _currentDirectory();
    final outPath = p.normalize(
      p.isAbsolute(parsed.option('out') ?? '')
          ? parsed.option('out')!
          : p.join(
              cwd,
              parsed.option('out') ??
                  FormalImportResult.kSuggestedOutputFilename,
            ),
    );
    final input = parsed.rest.single;
    final result = switch (kind) {
      FormalImportKind.sby => _sbyImporter.importJobs(
        path: p.isAbsolute(input) ? input : p.join(cwd, input),
        outputDirectory: p.dirname(outPath),
        tasks: <String>[
          for (final raw in parsed.multiOption('task'))
            for (final task in raw.split(','))
              if (task.trim().isNotEmpty) task.trim(),
        ],
        sbyBinary: parsed.option('sby-binary'),
      ),
      FormalImportKind.eqy => _eqyImporter.importFile(
        path: p.isAbsolute(input) ? input : p.join(cwd, input),
        outputDirectory: p.dirname(outPath),
        eqyBinary: parsed.option('eqy-binary'),
      ),
    };
    await _writeText(outPath, result.simcruxYaml);

    _stdoutWriter(
      'simcrux: wrote $outPath (${result.testCount} '
      '${result.testCount == 1 ? 'test' : 'tests'} from '
      '${result.jobs.length} job '
      '${result.jobs.length == 1 ? 'file' : 'files'}: '
      '${result.jobs.join(', ')})',
    );
    for (final warning in result.warnings) {
      _stderrWriter('simcrux: [${warning.code}] ${warning.message}');
    }
    final binaryOption = switch (kind) {
      FormalImportKind.sby => 'sby-binary',
      FormalImportKind.eqy => 'eqy-binary',
    };
    if (parsed.option(binaryOption) != null) {
      _stderrWriter(
        'simcrux: this config names a program for SimCrux to run '
        '(formal.${binaryOption.replaceAll('-', '_')}), which a project '
        'file may not do until you allow it. $kProjectToolingRemedy',
      );
    }
    return FormalImportCliResult(
      outputPath: outPath,
      testCount: result.testCount,
      jobs: result.jobs,
      warnings: result.warnings,
    );
  }

  static String _headerFor(FormalImportKind kind) => switch (kind) {
    FormalImportKind.sby =>
      'Usage: simcrux ${kind.subcommand} <file.sby|dir> [options]\n\n'
          'Reads a SymbiYosys job file (or every .sby directly in a '
          'directory) into one\nSimCrux test per task and writes an '
          'inspectable simcrux.yaml you own.\nNothing is run.',
    FormalImportKind.eqy =>
      'Usage: simcrux ${kind.subcommand} <file.eqy> [options]\n\n'
          'Reads an EQY equivalence-check file into one SimCrux test, whose '
          'row reports\nevery partition EQY proves, and writes an '
          'inspectable simcrux.yaml you own.\nNothing is run.',
  };

  static ArgParser _parserFor(FormalImportKind kind) {
    final parser = ArgParser()
      ..addOption(
        'out',
        abbr: 'o',
        help:
            'Where to write the generated project file. Defaults to '
            './simcrux.yaml. Job-file paths inside it are written relative '
            'to this file when they lie below it.',
        valueHelp: 'path',
      );
    switch (kind) {
      case FormalImportKind.sby:
        parser
          ..addMultiOption(
            'task',
            help:
                'Import only this [tasks] name. Repeat it, or give a '
                'comma-separated list. Default: every task.',
            valueHelp: 'name',
          )
          ..addOption(
            'sby-binary',
            help: 'Path to the SymbiYosys binary, when `sby` is not on PATH.',
            valueHelp: 'path',
          );
      case FormalImportKind.eqy:
        parser.addOption(
          'eqy-binary',
          help: 'Path to the EQY binary, when `eqy` is not on PATH.',
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
