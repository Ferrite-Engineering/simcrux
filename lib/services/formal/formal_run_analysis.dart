// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/formal_diagnostic.dart';
import 'package:simcrux/domain/models/sby_script.dart';
import 'package:simcrux/services/formal/formal_containment.dart';
import 'package:simcrux/services/formal/formal_design_reader.dart';
import 'package:simcrux/services/formal/pretrace_detector.dart';
import 'package:simcrux/services/formal/sva_refusal_classifier.dart';

/// What SimCrux worked out about one finished `sby` task beyond its
/// verdict: which frontend read the design, what it refused, and what the
/// elaborated design holds.
@immutable
class FormalRunAnalysis {
  /// Creates an analysis.
  const FormalRunAnalysis({
    this.frontend = FormalFrontend.unknown,
    this.refusal,
    this.facts,
    this.sourceAsserts = 0,
    this.sourceCovers = 0,
    this.frontendError,
    this.notes = const <String>[],
  });

  /// Nothing known.
  static const FormalRunAnalysis none = FormalRunAnalysis();

  /// The frontend that read the design.
  final FormalFrontend frontend;

  /// The classified SVA refusal, when the frontend refused one.
  final SvaRefusal? refusal;

  /// The elaborated design's formal cells, when it could be read.
  final FormalDesignFacts? facts;

  /// `assert` statements in the sources the task read.
  final int sourceAsserts;

  /// `cover` statements in the sources the task read.
  final int sourceCovers;

  /// The frontend's first error line, verbatim, for a refusal that is not
  /// about an assertion.
  final String? frontendError;

  /// Run-log notes about checks that could not be made.
  final List<String> notes;

  /// Whether a property of the kind [mode] checks was declared in the
  /// sources but none reached the elaborated design.
  bool droppedFor(String? mode) {
    final facts = this.facts;
    if (facts == null) return false;
    final cover = mode?.toLowerCase() == 'cover';
    final declared = cover ? sourceCovers : sourceAsserts;
    if (declared == 0) return false;
    final kind = cover ? 'cover' : 'assert';
    return facts.count(kind) == 0;
  }
}

/// Reads a finished task's directory for [FormalRunAnalysis]: the Yosys
/// log, the source copies in `src/`, and the elaborated design.
///
/// Every read is bounded and contained in the task directory.
class FormalRunAnalyser {
  /// Creates an analyser.
  const FormalRunAnalyser({
    this.designReader = const FormalDesignReader(),
    this.classifier = const SvaRefusalClassifier(),
  });

  /// Converts and analyses the elaborated design.
  final FormalDesignReader designReader;

  /// Classifies refusals.
  final SvaRefusalClassifier classifier;

  /// The most lines kept from the Yosys log.
  static const int kMaxLogLines = 20000;

  /// The largest source file read for a statement or a count.
  static const int kMaxSourceBytes = 8 * 1024 * 1024;

  /// Analyses [taskDirectory] after `sby` exited.
  ///
  /// [logLines] are the task's own log lines that mention an error (the
  /// `sby` stream). [classify] asks for the refusal (a run that stopped
  /// before a verdict); [readDesign] for the elaborated design (a run that
  /// reached one).
  Future<FormalRunAnalysis> analyse({
    required String taskDirectory,
    required String? task,
    required SbyScript? script,
    required List<String> logLines,
    required bool classify,
    required bool readDesign,
    required String yosys,
    Map<String, String>? environment,
  }) async {
    final notes = <String>[];
    final designLog = await _readDesignLog(taskDirectory);
    final frontend = SvaRefusalClassifier.detectFrontend(
      designLog: designLog,
      script: script?.scriptFor(task) ?? const <String>[],
    );
    final src = p.join(taskDirectory, 'src');
    final cache = <String, String?>{};
    String? sourceText(String file) => cache.putIfAbsent(file, () {
      final relative = p.isAbsolute(file) ? p.basename(file) : file;
      final path = FormalContainment.containedPath(src, p.join(src, relative));
      if (path == null) return null;
      final f = File(path);
      try {
        if (!f.existsSync() || f.lengthSync() > kMaxSourceBytes) return null;
        return f.readAsStringSync();
      } on FileSystemException {
        return null;
      }
    });

    SvaRefusal? refusal;
    String? frontendError;
    if (classify) {
      // The Yosys log first: it holds the frontend's full message on every
      // build, and is the only place builds before 20261021 keep it.
      final lines = <String>[...designLog, ...logLines];
      refusal = classifier.classify(
        lines: lines,
        frontend: frontend,
        readSource: (file, line) {
          final text = sourceText(file);
          return text == null
              ? null
              : SvaRefusalClassifier.statementAt(text, line);
        },
      );
      if (refusal == null) {
        for (final line in lines) {
          final at = line.indexOf('ERROR:');
          final lower = line.indexOf(': error:');
          if (at >= 0 && !line.contains('Design elaboration failed')) {
            frontendError = line.substring(at).trim();
            break;
          }
          if (lower >= 0) {
            frontendError = line.substring(lower + 2).trim();
            break;
          }
        }
      }
    }

    FormalDesignFacts? facts;
    var asserts = 0;
    var covers = 0;
    if (readDesign) {
      final read = await designReader.read(
        taskDirectory: taskDirectory,
        yosys: yosys,
        environment: environment,
      );
      facts = read.facts;
      if (read.note != null) notes.add(read.note!);
      if (facts != null) {
        for (final name in _sourceNames(src)) {
          final text = sourceText(name);
          if (text == null) continue;
          asserts += countSourceProperties(text, 'assert');
          covers += countSourceProperties(text, 'cover');
        }
      }
    }
    return FormalRunAnalysis(
      frontend: frontend,
      refusal: refusal,
      facts: facts,
      sourceAsserts: asserts,
      sourceCovers: covers,
      frontendError: frontendError,
      notes: List<String>.unmodifiable(notes),
    );
  }

  static final RegExp _blockComment = RegExp(r'/\*.*?\*/', dotAll: true);
  static final RegExp _lineComment = RegExp(r'//[^\n]*');

  /// How many `assert` or `cover` statements ([kind]) [text] declares,
  /// immediate or concurrent, comments excluded. Preprocessor branches are
  /// not evaluated, so this is an upper bound; the dropped-property check
  /// only uses it to tell "none declared" from "some declared".
  static int countSourceProperties(String text, String kind) {
    final code = text
        .replaceAll(_blockComment, ' ')
        .replaceAll(_lineComment, ' ');
    return RegExp(
      '\\b$kind\\b\\s*(?:property\\b|final\\b|#0\\b|\\()',
    ).allMatches(code).length;
  }

  /// The source files `sby` copied into [src], relative to it.
  static List<String> _sourceNames(String src) {
    final dir = Directory(src);
    if (!dir.existsSync()) return const <String>[];
    final names = <String>[];
    try {
      for (final entity in dir.listSync(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final ext = p.extension(entity.path).toLowerCase();
        if (ext != '.sv' && ext != '.v' && ext != '.svh' && ext != '.vh') {
          continue;
        }
        names.add(p.relative(entity.path, from: src));
      }
    } on FileSystemException {
      return const <String>[];
    }
    return names;
  }

  /// The lines of `model/design.log` that matter here (frontend banners
  /// and errors, and the source line a slang error quotes), bounded.
  static Future<List<String>> _readDesignLog(String taskDirectory) async {
    final path = FormalContainment.containedPath(
      taskDirectory,
      p.join(taskDirectory, 'model', 'design.log'),
    );
    if (path == null) return const <String>[];
    final file = File(path);
    if (!file.existsSync()) return const <String>[];
    final kept = <String>[];
    var seen = 0;
    try {
      await for (final line
          in file
              .openRead()
              .transform(const Utf8Decoder(allowMalformed: true))
              .transform(const LineSplitter())) {
        if (++seen > kMaxLogLines) break;
        if (line.contains('Executing') ||
            line.contains('ERROR') ||
            line.contains('error:') ||
            line.contains('Source line') ||
            line.contains('Verific')) {
          kept.add(line);
        }
      }
    } on FileSystemException {
      return kept;
    }
    return kept;
  }
}
