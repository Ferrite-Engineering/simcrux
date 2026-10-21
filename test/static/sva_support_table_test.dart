// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// The docs-site SVA support table is generated from the measured probe
// matrix and committed; this keeps the committed file equal to what the
// generator makes of the committed captures, so the table can never say
// something the matrix did not measure. The engine canary re-measures the
// matrix and checks the table rows against that.
//
// MUTATION: edit a cell of docs-site/generated/sva-support-table.md by hand
// and this fails.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/generate_sva_support_table.dart' as gen;

void main() {
  test('the committed table is what the generator makes of the matrix', () {
    final provenance = gen.provenanceOf(
      File(gen.kProvenance).readAsStringSync(),
    );
    final rows = gen.svaRows(
      File('${gen.kMatrixDir}/sva_matrix.expected.json').readAsStringSync(),
      File('${gen.kMatrixDir}/captured/results.tsv').readAsStringSync(),
    );
    expect(rows, hasLength(51));
    final committed = File(gen.kDefaultOut);
    expect(committed.existsSync(), isTrue, reason: gen.kDefaultOut);
    expect(
      committed.readAsStringSync(),
      gen.svaSupportTable(
        rows,
        build: provenance.build,
        date: provenance.date,
      ),
      reason:
          'run `dart run tool/generate_sva_support_table.dart` and commit '
          'the result',
    );
  });

  test('every probe was measured on both frontends', () {
    final rows = gen.svaRows(
      File('${gen.kMatrixDir}/sva_matrix.expected.json').readAsStringSync(),
      File('${gen.kMatrixDir}/captured/results.tsv').readAsStringSync(),
    );
    for (final row in rows) {
      expect(row.builtinAccepted, isNotNull, reason: row.probe);
      expect(row.slangAccepted, isNotNull, reason: row.probe);
    }
  });

  test('the table names a measurement date and build', () {
    final text = File(gen.kDefaultOut).readAsStringSync();
    expect(
      text,
      matches(
        RegExp(r'Measured \d{4}-\d{2}-\d{2} on OSS CAD Suite build \d{8}'),
      ),
    );
    expect(text, isNot(contains('—')), reason: 'no em dashes in copy');
  });
}
