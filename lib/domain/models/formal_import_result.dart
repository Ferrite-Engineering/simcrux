// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

/// A non-fatal finding of a formal import, echoed into the emitted file's
/// header comment.
@immutable
class FormalImportWarning {
  /// Creates a warning.
  const FormalImportWarning({required this.code, required this.message});

  /// Stable machine code (`assertions_disabled`, `task_not_declared`).
  final String code;

  /// Plain-English explanation.
  final String message;

  @override
  String toString() => '[$code] $message';
}

/// Thrown when the named input is not something the importer can read: no
/// job file there, or none of the requested tasks declared.
class FormalImportException implements Exception {
  /// Creates the exception.
  const FormalImportException({required this.path, required this.message});

  /// The path the importer was pointed at.
  final String path;

  /// What is wrong with it.
  final String message;

  @override
  String toString() => '$path: $message';
}

/// What a formal import produced: a `simcrux.yaml` the user owns.
@immutable
class FormalImportResult {
  /// Creates a result.
  const FormalImportResult({
    required this.simcruxYaml,
    required this.testCount,
    required this.jobs,
    this.warnings = const <FormalImportWarning>[],
  });

  /// Filename the importers suggest for the emitted project file.
  static const String kSuggestedOutputFilename = 'simcrux.yaml';

  /// The emitted project file.
  final String simcruxYaml;

  /// How many tests it declares: one per task.
  final int testCount;

  /// The job files imported, by basename, in emission order. One suite
  /// each.
  final List<String> jobs;

  /// Non-fatal findings.
  final List<FormalImportWarning> warnings;
}
