// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

/// A non-fatal issue the RISC-V arch-test importer hit while enumerating.
///
/// Mirrors `FuseSoCImportWarning`: a stable [code] a test can assert on, and
/// a human [message] that is echoed into the generated YAML's header comment
/// so the user has a record of what did not translate cleanly.
@immutable
class RiscvImportWarning {
  /// Creates a [RiscvImportWarning].
  const RiscvImportWarning({required this.code, required this.message});

  /// Stable machine-readable code (e.g. `unknown_extension`).
  final String code;

  /// Human-readable description.
  final String message;

  @override
  bool operator ==(Object other) =>
      other is RiscvImportWarning &&
      other.code == code &&
      other.message == message;

  @override
  int get hashCode => Object.hash(code, message);

  @override
  String toString() => 'RiscvImportWarning($code): $message';
}

/// What `RiscvArchTestImporter` produced.
///
/// The headline field is [simcruxYaml] — **inspectable SimCrux config the
/// user owns**, not a hidden mapping inside a driver. That is the
/// `FuseSoCImporter` precedent and it is the reason enumeration is an
/// importer at all: the user can read, diff,
/// edit and commit the enumeration, and can delete or re-tag any test the
/// heuristics got wrong.
@immutable
class RiscvImportResult {
  /// Creates a [RiscvImportResult].
  RiscvImportResult({
    required this.simcruxYaml,
    required this.suggestedOutputFilename,
    required this.testCount,
    required List<String> extensions,
    required List<RiscvImportWarning> warnings,
  }) : extensions = List<String>.unmodifiable(extensions),
       warnings = List<RiscvImportWarning>.unmodifiable(warnings);

  /// The generated project file text.
  final String simcruxYaml;

  /// Filename to write [simcruxYaml] to, relative to the user's choice of
  /// directory.
  final String suggestedOutputFilename;

  /// How many `TestSpec`s the emitted YAML will produce — one per
  /// architectural test. There is no fan-out anywhere downstream, so this
  /// is also the number of dashboard rows and the number of `TestResult`s.
  final int testCount;

  /// Extensions found, in emission order. One suite per entry.
  final List<String> extensions;

  /// Non-fatal issues, also echoed into the YAML header comment.
  final List<RiscvImportWarning> warnings;
}

/// Thrown when the importer cannot produce any output at all.
class RiscvImportException implements Exception {
  /// Creates a [RiscvImportException].
  const RiscvImportException({required this.path, required this.message});

  /// The path that could not be imported.
  final String path;

  /// Human-readable description.
  final String message;

  @override
  String toString() => 'RiscvImportException ($path): $message';
}
