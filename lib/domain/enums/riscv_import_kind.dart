// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// Which of the two RISC-V ecosystems an import reads.
///
/// The pair exists as an enum rather than two bare strings because the
/// sub-command word is needed in three layers at once — `core/` matches it
/// in `CliArgParser`, `services/` parses the flags behind it in
/// `RiscvImportCli`, and `features/`-adjacent menu handlers name the same
/// two imports — and `domain/` is the only layer all three may depend on.
/// A literal repeated across those three would drift the first time one of
/// them was renamed.
enum RiscvImportKind {
  /// A `riscv-arch-test` checkout: one SimCrux test per architectural test,
  /// driven by `riscv_arch`.
  archTest('import-riscv-arch-test'),

  /// A riscv-formal `checks/` directory as written by `genchecks.py`: one
  /// SimCrux test per bounded proof, driven by `riscv_formal`.
  formal('import-riscv-formal');

  const RiscvImportKind(this.subcommand);

  /// The `simcrux <word>` sub-command that runs this import.
  final String subcommand;

  /// Parses a [subcommand] word back to its kind, or null when unknown.
  static RiscvImportKind? fromSubcommand(String? word) {
    for (final kind in RiscvImportKind.values) {
      if (kind.subcommand == word) return kind;
    }
    return null;
  }

  /// Both sub-command words, for the CLI parser's dispatch table.
  static List<String> get subcommands =>
      RiscvImportKind.values.map((k) => k.subcommand).toList(growable: false);
}
