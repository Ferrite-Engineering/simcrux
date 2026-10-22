// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:crux_io/crux_io.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/services/formal/formal_containment.dart';
import 'package:simcrux/services/formal/formal_reconciliation.dart';

/// The identity across runs of a property that carries no label.
///
/// A label (yosys-slang keeps the user's) is the identity when there is one.
/// For an unlabelled property it is the shared `crux-fnv1a64/1` signature
/// ([CruxSignature]) over the task, the kind, the project-relative file and
/// the property's source text, which is the scheme LintCrux baselines and
/// the SARIF fingerprints use. The line number is never a field: an edit
/// above a property must not make it a new property.
///
/// The text is the source line the property starts on. A property whose
/// source cannot be read gets no id rather than a guessed one: an id that
/// moved with the checkout would split a property's history. Two properties
/// of one kind written on one line share a signature, as two lint findings
/// with one message in one file do.
abstract final class FormalPropertyIdentity {
  /// The longest source file read, in bytes. A property in a file larger
  /// than this has no id.
  static const int kMaxSourceBytes = 4 * 1024 * 1024;

  /// The signature of one property, from its fields and source line.
  static String signature({
    required String task,
    required String kind,
    required String file,
    required String sourceText,
  }) => CruxSignature.compute(<String>[
    task,
    kind.toUpperCase(),
    file,
  ], sourceText);

  /// The signature for every unlabelled property in [properties] whose
  /// source is readable, keyed by [FormalPropertyResult.key].
  ///
  /// A source is looked for, contained, under [projectRoot] (the file the
  /// result names); then where the `.sby` file's `[files]` ([files], relative
  /// to [sbyDirectory]) puts it, inside [projectRoot] or, with none, inside
  /// [sbyDirectory]; then in the task directory's `src/` copy that `sby`
  /// made. Reads are streamed and bounded, never a whole file on the calling
  /// isolate.
  static Future<Map<String, String>> signatures({
    required Iterable<FormalPropertyResult> properties,
    required String? projectRoot,
    required String taskDirectory,
    String? sbyDirectory,
    Map<String, String> files = const <String, String>{},
  }) async {
    final lines = <String, List<String>?>{};
    final out = <String, String>{};
    for (final property in properties) {
      if (property.label != null) continue;
      final file = property.file;
      final line = property.line;
      if (file == null || line == null || line < 1) continue;
      final candidates = <String>[
        if (projectRoot != null) ?_contained(projectRoot, file),
        if (sbyDirectory != null)
          ?_contained(
            projectRoot ?? sbyDirectory,
            p.isAbsolute(files[file] ?? file)
                ? files[file] ?? file
                : p.join(sbyDirectory, files[file] ?? file),
          ),
        ?_contained(p.join(taskDirectory, 'src'), file),
      ];
      String? text;
      for (final candidate in candidates) {
        final source = lines[candidate] ??= await _readLines(candidate);
        if (source != null && line <= source.length) {
          text = source[line - 1];
          break;
        }
      }
      if (text == null || text.trim().isEmpty) continue;
      out[property.key] = signature(
        task: property.task,
        kind: property.kind,
        file: file,
        sourceText: text,
      );
    }
    return out;
  }

  static String? _contained(String root, String file) {
    final path = p.isAbsolute(file) ? file : p.join(root, file);
    return FormalContainment.containedPath(root, path);
  }

  static Future<List<String>?> _readLines(String path) async {
    try {
      final handle = File(path);
      if (!handle.existsSync() || handle.lengthSync() > kMaxSourceBytes) {
        return null;
      }
      return await handle
          .openRead()
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .toList();
    } on FileSystemException {
      return null;
    }
  }
}
