// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/formal_config.dart';
import 'package:simcrux/domain/models/formal_import_result.dart';
import 'package:simcrux/domain/models/sby_script.dart';
import 'package:simcrux/services/import/import_yaml.dart';

/// One SymbiYosys job file and the tests it becomes.
class SbyImportJob {
  /// Creates a job.
  const SbyImportJob({
    required this.path,
    required this.script,
    required this.tasks,
  });

  /// Absolute path of the `.sby` file.
  final String path;

  /// What the file declares.
  final SbyScript script;

  /// The tasks to import, in declaration order. A single null entry for a
  /// file without `[tasks]`: one test that runs the file's default task.
  final List<String?> tasks;
}

/// Reads SymbiYosys `.sby` job files into **one SimCrux test per task**,
/// emitted as an inspectable `simcrux.yaml` for the `sby` driver.
///
/// ## Why one test per task
///
/// One `sby` invocation over a multi-task file prints one `DONE (…)` line
/// per task, and the job model has no fan-out: one `TestSpec` is one
/// verdict. So the enumeration happens here, before the scheduler, and each
/// task becomes its own test with its own timeout, cancel and verdict; the
/// riscv-formal importer does the same through [expandTasks].
///
/// ## What it emits
///
/// - `defaults.simulator: sby` and the `string_match` detector on
///   `SbyLogReader.kPassMarker` ([writeSbyPassDetector]).
/// - One suite per job file, named after it, one test per task with
///   `formal.sby_file` (relative to the emitted file's directory when it
///   lies below it) and `formal.task`.
/// - `top:` is the test name: a required `TestSpec` field the job file, not
///   SimCrux, really decides.
///
/// Nothing is run and nothing is written into the scanned tree; the caller
/// decides where the file goes.
class SbyProjectImporter {
  /// Creates an importer. The file-system hooks are injected so tests run
  /// against an in-memory tree.
  SbyProjectImporter({
    List<String> Function(String dir)? listDirectory,
    String Function(String path)? readFile,
    bool Function(String path)? directoryExists,
    bool Function(String path)? fileExists,
  }) : _listDirectory = listDirectory ?? _defaultListDirectory,
       _readFile = readFile ?? _defaultReadFile,
       _directoryExists = directoryExists ?? _defaultDirectoryExists,
       _fileExists = fileExists ?? _defaultFileExists;

  final List<String> Function(String dir) _listDirectory;
  final String Function(String path) _readFile;
  final bool Function(String path) _directoryExists;
  final bool Function(String path) _fileExists;

  static List<String> _defaultListDirectory(String dir) {
    final directory = Directory(dir);
    if (!directory.existsSync()) return const <String>[];
    return directory.listSync().map((e) => e.path).toList(growable: false)
      ..sort();
  }

  static String _defaultReadFile(String path) => File(path).readAsStringSync();

  static bool _defaultDirectoryExists(String path) =>
      Directory(path).existsSync();

  static bool _defaultFileExists(String path) => File(path).existsSync();

  /// The tests a job file becomes: one per `[tasks]` name, or a single
  /// null for a file that declares none.
  ///
  /// Shared with the riscv-formal importer, so the two cannot disagree about
  /// how a multi-task file is split.
  static List<String?> expandTasks(SbyScript script) =>
      script.tasks.isEmpty ? const <String?>[null] : script.tasks;

  /// Parses one job file. Never throws: an unreadable file parses as an
  /// empty script.
  SbyScript readScript(String path) {
    try {
      return SbyScript.parse(_readFile(path));
    } on Object {
      return const SbyScript();
    }
  }

  /// The job files [path] names: the file itself, or every `.sby` directly
  /// inside a directory, sorted.
  ///
  /// Throws [FormalImportException] when [path] is neither, or a directory
  /// holds no job file.
  List<String> jobFiles(String path) {
    final abs = p.normalize(p.absolute(path));
    if (_fileExists(abs)) {
      if (p.extension(abs).toLowerCase() != '.sby') {
        throw FormalImportException(
          path: abs,
          message:
              'Not a SymbiYosys job file: point at a `.sby` file, or a '
              'directory holding them.',
        );
      }
      return <String>[abs];
    }
    if (!_directoryExists(abs)) {
      throw FormalImportException(
        path: abs,
        message: 'No such file or directory.',
      );
    }
    final found = <String>[
      for (final entry in _listDirectory(abs))
        if (p.extension(entry).toLowerCase() == '.sby' && _fileExists(entry))
          p.normalize(entry),
    ]..sort();
    if (found.isEmpty) {
      throw FormalImportException(
        path: abs,
        message: 'No `.sby` job files directly inside this directory.',
      );
    }
    return found;
  }

  /// Reads the job files [path] names and the tests each becomes.
  ///
  /// [tasks], when non-empty, keeps only those task names; a job file that
  /// declares none of them is left out. Throws [FormalImportException] when
  /// nothing is left.
  List<SbyImportJob> enumerate(String path, {List<String> tasks = const []}) {
    final files = jobFiles(path);
    final wanted = tasks.toSet();
    final jobs = <SbyImportJob>[];
    for (final file in files) {
      final script = readScript(file);
      final expanded = expandTasks(script);
      final kept = wanted.isEmpty
          ? expanded
          : expanded.where((t) => t != null && wanted.contains(t)).toList();
      if (kept.isEmpty) continue;
      jobs.add(SbyImportJob(path: file, script: script, tasks: kept));
    }
    if (jobs.isEmpty) {
      final declared = <String>{
        for (final file in files) ...readScript(file).tasks,
      }.toList()..sort();
      throw FormalImportException(
        path: p.normalize(p.absolute(path)),
        message: declared.isEmpty
            ? 'No job file here declares a [tasks] section, so there is no '
                  'task to select. Import without --task.'
            : 'No job file here declares the task(s) '
                  '${tasks.join(', ')}. Declared tasks: '
                  '${declared.join(', ')}.',
      );
    }
    return jobs;
  }

  /// Imports the job files [path] names and emits a project file for a
  /// file in [outputDirectory].
  ///
  /// [sbyBinary] lands once under `defaults.formal.sby_binary`; the loader
  /// honours it only when project tooling is allowed.
  FormalImportResult importJobs({
    required String path,
    required String outputDirectory,
    List<String> tasks = const [],
    String? sbyBinary,
  }) {
    final jobs = enumerate(path, tasks: tasks);
    final warnings = <FormalImportWarning>[];
    final outDir = p.normalize(p.absolute(outputDirectory));
    final buf = StringBuffer()
      ..writeln('# Generated by the SimCrux SymbiYosys importer.')
      ..writeln('# Source: ${p.normalize(p.absolute(path))}')
      ..writeln(
        '# One test per task: SimCrux schedules, times out and cancels each '
        'one',
      )
      ..writeln('# independently and reads each verdict from its own log.')
      ..writeln('#')
      ..writeln(
        '# This file is yours: read it, diff it, edit it, commit it. '
        'Re-running the importer',
      )
      ..writeln('# overwrites it.');
    for (final job in jobs) {
      final how = job.tasks
          .map(job.script.assertionsDisabledFor)
          .whereType<String>()
          .firstOrNull;
      if (how != null) {
        warnings.add(
          FormalImportWarning(
            code: 'assertions_disabled',
            message:
                '`${p.basename(job.path)}` reads the design with '
                '${how == 'noassert' ? '-noassert' : '--ignore-assertions'}, '
                'so its assertions are not checked and a pass says nothing '
                'about them.',
          ),
        );
      }
    }
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
      ..writeln('  simulator: ${FormalConfig.kSbySimulatorId}');
    writeSbyPassDetector(buf);
    if (sbyBinary != null && sbyBinary.isNotEmpty) {
      buf
        ..writeln('  formal:')
        ..writeln('    sby_binary: ${importYamlScalar(sbyBinary)}');
    }
    buf
      ..writeln()
      ..writeln('suites:');
    final usedKeys = <String>{};
    var testCount = 0;
    for (final job in jobs) {
      final base = p.basenameWithoutExtension(job.path);
      var key = importYamlKey(base);
      for (var n = 2; usedKeys.contains(key); n++) {
        key = '${importYamlKey(base)}_$n';
      }
      usedKeys.add(key);
      final sbyFile = _sbyFileFor(job.path, outDir);
      final count = job.tasks.length;
      buf
        ..writeln('  $key:')
        ..writeln(
          '    description: SymbiYosys job ${p.basename(job.path)} '
          '($count ${count == 1 ? 'task' : 'tasks'}).',
        )
        ..writeln('    tests:');
      for (final task in job.tasks) {
        final name = task ?? base;
        buf
          ..writeln('      - name: ${importYamlScalar(name)}')
          // `top:` is mandatory on every TestSpec; the job file's [script]
          // picks the real top level, so the test name stands in.
          ..writeln('        top: ${importYamlScalar(name)}')
          ..writeln('        formal:')
          ..writeln('          sby_file: ${importYamlScalar(sbyFile)}');
        if (task != null) {
          buf.writeln('          task: ${importYamlScalar(task)}');
        }
        testCount++;
      }
    }
    return FormalImportResult(
      simcruxYaml: buf.toString(),
      testCount: testCount,
      jobs: <String>[for (final job in jobs) p.basename(job.path)],
      warnings: List<FormalImportWarning>.unmodifiable(warnings),
    );
  }

  /// [sbyPath] as the emitted file should spell it: relative (with `/`)
  /// when it lies under [outDir], absolute otherwise, so the project file
  /// keeps working when its directory moves with the job files and never
  /// depends on where the importer ran.
  static String _sbyFileFor(String sbyPath, String outDir) {
    if (p.isWithin(outDir, sbyPath)) {
      return p.relative(sbyPath, from: outDir).replaceAll(r'\', '/');
    }
    return sbyPath;
  }
}
