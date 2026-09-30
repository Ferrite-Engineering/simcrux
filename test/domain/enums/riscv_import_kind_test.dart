// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/riscv_import_kind.dart';

void main() {
  group('RiscvImportKind', () {
    test('every kind has a distinct, stable sub-command word', () {
      expect(RiscvImportKind.archTest.subcommand, 'import-riscv-arch-test');
      expect(RiscvImportKind.formal.subcommand, 'import-riscv-formal');
      expect(
        RiscvImportKind.values.map((k) => k.subcommand).toSet(),
        hasLength(RiscvImportKind.values.length),
      );
    });

    test('subcommands lists every kind, in declaration order', () {
      expect(RiscvImportKind.subcommands, [
        'import-riscv-arch-test',
        'import-riscv-formal',
      ]);
    });

    test('fromSubcommand round-trips every kind', () {
      for (final kind in RiscvImportKind.values) {
        expect(RiscvImportKind.fromSubcommand(kind.subcommand), kind);
      }
    });

    test('fromSubcommand returns null for anything else', () {
      // The bootstrap dispatches on this, so a null for `export-dashboard`
      // (and for the no-sub-command case) is what keeps the other CLI paths
      // reachable.
      for (final word in const [
        null,
        '',
        'export-dashboard',
        'import-fusesoc',
        'Import-RISCV-Arch-Test',
      ]) {
        expect(RiscvImportKind.fromSubcommand(word), isNull, reason: '$word');
      }
    });
  });
}
