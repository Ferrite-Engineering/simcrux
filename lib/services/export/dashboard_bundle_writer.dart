// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/core/telemetry/crux_telemetry_headless.dart';
import 'package:simcrux/services/result_store/ndjson_recovery.dart';
import 'package:simcrux/services/result_store/streaming_results_writer.dart';

/// Result of [DashboardBundleWriter.run].
class DashboardBundleResult {
  /// Creates a [DashboardBundleResult].
  const DashboardBundleResult({
    required this.outputDir,
    required this.bytesWritten,
    required this.filesCopied,
  });

  /// Absolute path to the populated directory.
  final String outputDir;

  /// Total bytes written across `simcrux-results.json` and the web
  /// bundle copy. Useful for the CLI summary line.
  final int bytesWritten;

  /// Number of bundle files copied (zero when the user did not pass
  /// `--web-bundle`).
  final int filesCopied;
}

/// Writes a self-contained dashboard bundle into a destination
/// directory:
///
/// - `simcrux-results.json` — either copied verbatim from `--results`
///   (consolidated JSON) or synthesized from a streaming
///   `results.ndjson` via [StreamingResultsHydrator] + the existing
///   JSON exporter.
/// - The contents of `--web-bundle <dir>` (typically the output of
///   `flutter build web --target lib/main_web.dart`) copied
///   alongside, when supplied.
///
/// Designed for the `simcrux export-dashboard <out-dir>` CLI flow that
/// feeds the read-only web dashboard. Pure
/// `dart:io` — never invokes Flutter.
class DashboardBundleWriter {
  /// Creates a [DashboardBundleWriter] with injectable seams so unit
  /// tests can drive it off in-memory state.
  DashboardBundleWriter({
    Future<String> Function(String path)? readText,
    Future<void> Function(String path, String contents)? writeText,
    Future<void> Function(String src, String dst)? copyFile,
    Stream<FileSystemEntity> Function(String dir)? listDirectory,
    Future<void> Function(String dir)? ensureDirectory,
    void Function(String line)? stdoutWriter,
    NdjsonRecovery recovery = const FileNdjsonRecovery(),
    this.telemetry = const NoopTelemetryService(),
  }) : _readText = readText ?? _defaultReadText,
       _writeText = writeText ?? _defaultWriteText,
       _copyFile = copyFile ?? _defaultCopyFile,
       _listDirectory = listDirectory ?? _defaultListDirectory,
       _ensureDirectory = ensureDirectory ?? _defaultEnsureDirectory,
       _stdoutWriter = stdoutWriter ?? _defaultStdout,
       // Public param can't use the underscore-prefixed field name, so an
       // initializing formal isn't available here.
       // ignore: prefer_initializing_formals
       _recovery = recovery;

  /// Where this invocation's `export.completed` counter goes.
  ///
  /// Defaults to [NoopTelemetryService]; `bootstrap` supplies the real one
  /// through [resolveHeadlessTelemetry], so `simcrux export-dashboard` obeys
  /// the same `--ci` consent rule as `simcrux --ci` — a machine whose GUI has
  /// not said yes exports exactly as before and sends nothing.
  final TelemetryService telemetry;

  /// Repairs a crash-truncated `results.ndjson` before it is decoded.
  /// Defaults to [FileNdjsonRecovery] (the production behaviour); tests
  /// pass [NoopNdjsonRecovery] to stay off the disk.
  final NdjsonRecovery _recovery;

  final Future<String> Function(String path) _readText;
  final Future<void> Function(String path, String contents) _writeText;
  final Future<void> Function(String src, String dst) _copyFile;
  final Stream<FileSystemEntity> Function(String dir) _listDirectory;
  final Future<void> Function(String dir) _ensureDirectory;
  final void Function(String line) _stdoutWriter;

  /// Parses the `simcrux export-dashboard …` sub-command arguments
  /// and runs the bundle writer.
  Future<DashboardBundleResult> run(List<String> args) async {
    final parser = ArgParser()
      ..addOption(
        'results',
        help:
            'Path to the source results file. Accepts either a '
            'consolidated simcrux-results.json or a streaming '
            'results.ndjson. Defaults to ./results.ndjson.',
        valueHelp: 'path',
      )
      ..addOption(
        'web-bundle',
        help:
            'Directory containing a pre-built Flutter web bundle '
            '(typically build/web/ from `flutter build web --target '
            'lib/main_web.dart`). When provided its contents are '
            'copied alongside simcrux-results.json.',
        valueHelp: 'dir',
      );
    final ArgResults parsed;
    try {
      parsed = parser.parse(args);
    } on FormatException catch (e) {
      throw DashboardBundleException(e.message);
    }
    if (parsed.rest.length != 1) {
      throw const DashboardBundleException(
        'simcrux export-dashboard expects exactly one positional '
        'argument (the output directory).',
      );
    }
    final outDir = p.normalize(p.absolute(parsed.rest.single));
    final resultsArg =
        parsed['results'] as String? ??
        p.join(Directory.current.path, 'results.ndjson');
    final webBundle = parsed['web-bundle'] as String?;
    await _ensureDirectory(outDir);

    final consolidated = await _resolveConsolidatedJson(resultsArg);
    final consolidatedPath = p.join(outDir, 'simcrux-results.json');
    await _writeText(consolidatedPath, consolidated);
    var bytesWritten = consolidated.length;

    var filesCopied = 0;
    if (webBundle != null) {
      final filesCopiedAndBytes = await _copyBundle(webBundle, outDir);
      filesCopied = filesCopiedAndBytes.files;
      bytesWritten += filesCopiedAndBytes.bytes;
    }

    // After every write, so a partial export is not counted as a completed
    // one. `web_bundle` is the one `format` token with no `ExportFormat`
    // constant behind it: this command writes a directory rather than encoding
    // a single document, which is exactly why it is a separate token instead
    // of being folded into `html`.
    telemetry.record(
      TelemetryEvent(
        'export.completed',
        properties: const <String, Object?>{'format': 'web_bundle'},
      ),
    );
    _stdoutWriter(
      'simcrux: wrote ${p.relative(consolidatedPath)} '
      '(+$filesCopied bundle files) → $outDir',
    );
    return DashboardBundleResult(
      outputDir: outDir,
      bytesWritten: bytesWritten,
      filesCopied: filesCopied,
    );
  }

  /// Reads [resultsPath] (which may be NDJSON or a consolidated JSON
  /// document) and returns the consolidated `simcrux-results.json`
  /// payload to write into the bundle.
  Future<String> _resolveConsolidatedJson(String resultsPath) async {
    final text = await _readText(resultsPath);
    final trimmed = text.trimLeft();
    final looksConsolidated =
        trimmed.startsWith('{') &&
        trimmed.trimRight().endsWith('}') &&
        !text.contains('\n{"type":"');
    if (looksConsolidated) {
      // Already in the consolidated shape — pass through verbatim.
      // (Do not run recovery here: a single-object consolidated file is
      // not a streaming NDJSON log and its "last line" is not a record.)
      return text;
    }
    // NDJSON path. A crash mid-run can leave a truncated/garbled trailing
    // record; repair the file in place before decoding so the export reads
    // a consistent prefix instead of choking on (or silently misreading)
    // the tail. Re-read afterwards to pick up the repaired content.
    await _recovery.recover(resultsPath);
    final repaired = await _readText(resultsPath);
    return _ndjsonToConsolidated(repaired);
  }

  String _ndjsonToConsolidated(String ndjsonText) {
    const reader = StreamingResultsReader();
    final doc = reader.decode(ndjsonText.split('\n'));
    const hydrator = StreamingResultsHydrator();
    final hydrated = hydrator.hydrate(doc);
    final runStarted = hydrated.run.startedAt.toUtc().toIso8601String();
    final runFinished = hydrated.run.finishedAt?.toUtc().toIso8601String();
    final tests = <Map<String, Object?>>[];
    for (final row in hydrated.rows) {
      final r = row.result;
      tests.add(<String, Object?>{
        'id': row.testId,
        'name': row.testName,
        'suite': row.suiteName,
        'simulator': row.simulatorId,
        'status': r.status.name,
        'runtime_ms': r.runtime.inMilliseconds,
        'started_at': r.startedAt.toUtc().toIso8601String(),
        'finished_at': r.finishedAt.toUtc().toIso8601String(),
        'exit_code': r.exitCode,
        'waveform_path': r.waveformPath,
        'stdout_path': r.stdoutPath,
        'stderr_path': r.stderrPath,
        'failure_message': r.failureMessage,
        if (r.metrics.isNotEmpty)
          'metrics': Map<String, String>.from(r.metrics),
      });
    }
    final consolidated = <String, Object?>{
      'version': 1,
      'config_path': doc.meta?.configPath,
      'run': <String, Object?>{
        'id': hydrated.run.id,
        'started_at': runStarted,
        'finished_at': ?runFinished,
        'total': tests.length,
      },
      'tests': tests,
    };
    return _prettyJson(consolidated);
  }

  Future<({int files, int bytes})> _copyBundle(
    String srcDir,
    String dstDir,
  ) async {
    var files = 0;
    var bytes = 0;
    await for (final entity in _listDirectory(srcDir)) {
      if (entity is! File) continue;
      final relative = p.relative(entity.path, from: srcDir);
      final dstPath = p.join(dstDir, relative);
      await _ensureDirectory(p.dirname(dstPath));
      await _copyFile(entity.path, dstPath);
      bytes += entity.lengthSync();
      files++;
    }
    return (files: files, bytes: bytes);
  }

  static Future<String> _defaultReadText(String path) =>
      File(path).readAsString();

  static Future<void> _defaultWriteText(String path, String contents) =>
      File(path).writeAsString(contents);

  static Future<void> _defaultCopyFile(String src, String dst) async {
    await File(src).copy(dst);
  }

  static Stream<FileSystemEntity> _defaultListDirectory(String dir) =>
      Directory(dir).list(recursive: true, followLinks: false);

  static Future<void> _defaultEnsureDirectory(String dir) async {
    final d = Directory(dir);
    if (!d.existsSync()) await d.create(recursive: true);
  }

  static void _defaultStdout(String line) {
    stdout.writeln(line);
  }
}

String _prettyJson(Object? doc) {
  final buf = StringBuffer();
  _writeJson(buf, doc, indent: '');
  return buf.toString();
}

void _writeJson(StringBuffer buf, Object? value, {required String indent}) {
  if (value is Map<String, Object?>) {
    buf.write('{');
    if (value.isEmpty) {
      buf.write('}');
      return;
    }
    final inner = '$indent  ';
    var first = true;
    for (final entry in value.entries) {
      if (!first) buf.write(',');
      buf
        ..write('\n')
        ..write(inner)
        ..write('"')
        ..write(_escape(entry.key))
        ..write('": ');
      _writeJson(buf, entry.value, indent: inner);
      first = false;
    }
    buf
      ..write('\n')
      ..write(indent)
      ..write('}');
  } else if (value is List<Object?>) {
    buf.write('[');
    if (value.isEmpty) {
      buf.write(']');
      return;
    }
    final inner = '$indent  ';
    for (var i = 0; i < value.length; i++) {
      if (i > 0) buf.write(',');
      buf
        ..write('\n')
        ..write(inner);
      _writeJson(buf, value[i], indent: inner);
    }
    buf
      ..write('\n')
      ..write(indent)
      ..write(']');
  } else if (value is String) {
    buf
      ..write('"')
      ..write(_escape(value))
      ..write('"');
  } else if (value is bool || value is num) {
    buf.write('$value');
  } else if (value == null) {
    buf.write('null');
  } else {
    buf
      ..write('"')
      ..write(_escape('$value'))
      ..write('"');
  }
}

String _escape(String s) {
  return s
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r')
      .replaceAll('\t', r'\t');
}

/// Thrown by [DashboardBundleWriter.run] on user error.
class DashboardBundleException implements Exception {
  /// Creates a [DashboardBundleException].
  const DashboardBundleException(this.message);

  /// Human-readable description of what went wrong.
  final String message;

  @override
  String toString() => 'simcrux export-dashboard: $message';
}
