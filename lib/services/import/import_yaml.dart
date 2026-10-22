// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/domain/models/eqy_outcome.dart';
import 'package:simcrux/domain/models/sby_outcome.dart';

// The YAML spelling helpers the formal importers share, so the general
// `.sby` importer and the riscv-formal importer quote a value the same way.

/// [key] as a YAML map key: anything outside `[A-Za-z0-9_-]` becomes `_`,
/// and an empty key becomes `imported`.
String importYamlKey(String key) {
  if (key.isEmpty) return 'imported';
  return key.replaceAll(RegExp('[^A-Za-z0-9_-]'), '_');
}

/// [value] as a YAML scalar, single-quoted when a plain scalar would be
/// read as something else.
String importYamlScalar(String value) {
  if (value.isEmpty) return "''";
  final needsQuote = RegExp(
    '[:#&*!|>\'"%@`{}\\[\\],?\\s]|^-',
  ).hasMatch(value);
  if (!needsQuote) return value;
  final escaped = value.replaceAll("'", "''");
  return "'$escaped'";
}

/// Writes the `pass_fail:` block every formal import emits under
/// `defaults:`, at [indent].
///
/// A required pass string that never appears is a fail by the detector's
/// documented semantics, never an `unknown` that would fall back to an exit
/// code. The literal is [SbyLogReader.kPassMarker], the constant the
/// driver's parser keys off, so the two cannot drift; and the scheduler
/// never lets a detector turn a `formal.verdict` other than `PASS` into a
/// pass, so the detector cannot undo the agreement rule either.
void writeSbyPassDetector(StringBuffer buf, {String indent = '  '}) =>
    _writePassDetector(buf, SbyLogReader.kPassMarker, indent);

/// Writes the `pass_fail:` block the EQY importer emits: the same shape,
/// keyed on [EqyLogReader.kPassMarker], the constant the `eqy` driver's log
/// reader parses.
void writeEqyPassDetector(StringBuffer buf, {String indent = '  '}) =>
    _writePassDetector(buf, EqyLogReader.kPassMarker, indent);

void _writePassDetector(StringBuffer buf, String marker, String indent) {
  buf
    ..writeln('${indent}pass_fail:')
    ..writeln('$indent  type: string_match')
    ..writeln("$indent  pass_string: '$marker'");
}
