// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// The golden reference model an architectural-compatibility run compares
/// the DUT against.
///
/// Both are ordinary user-installed binaries SimCrux locates and spawns —
/// nothing is bundled and nothing is auto-installed, so SimCrux conveys no
/// third-party engine and carries none of its redistribution obligations.
enum RiscvReferenceModel {
  /// The Sail RISC-V formal model's C emulator (`riscv_sim_RV32` /
  /// `riscv_sim_RV64`).
  ///
  /// The more authoritative of the two — it *is* the specification — and
  /// the harder of the two to obtain. On Windows there is no practical
  /// native build; the honest guidance is WSL2 or Spike.
  sail('sail'),

  /// The Spike ISA simulator (`spike`), the reference implementation.
  ///
  /// Easier to build than Sail on every platform and the pragmatic choice
  /// when Sail is not available.
  spike('spike');

  const RiscvReferenceModel(this.wireName);

  /// Stable token used in `simcrux.yaml`. Never localize or reformat it.
  final String wireName;

  /// Conventional executable name when the user configured no explicit
  /// `reference.path`. [xlen] selects Sail's per-width emulator; Spike is
  /// one binary for both widths.
  String defaultBinary({required int xlen}) => switch (this) {
    RiscvReferenceModel.sail => 'riscv_sim_RV$xlen',
    RiscvReferenceModel.spike => 'spike',
  };

  /// The conventional argument vector that makes this model execute [elf]
  /// and dump its architectural signature to [signaturePath].
  ///
  /// These are the invocations both projects document; a user with a
  /// non-standard build overrides or extends them through the `riscv:`
  /// block's `reference.args:`, which are spliced in after these flags and
  /// before the ELF path.
  ///
  /// [wordSize] is the signature granularity in bytes — Spike takes it on
  /// the command line, Sail infers it from the test's signature section.
  List<String> signatureArgs({
    required String isa,
    required String elf,
    required String signaturePath,
    required int wordSize,
  }) => switch (this) {
    RiscvReferenceModel.sail => <String>[
      '--test-signature',
      signaturePath,
      elf,
    ],
    RiscvReferenceModel.spike => <String>[
      '--isa=$isa',
      '+signature=$signaturePath',
      '+signature-granularity=$wordSize',
      elf,
    ],
  };

  /// Parses a [wireName] back to its enum value, or null when unknown.
  static RiscvReferenceModel? fromWireName(Object? raw) {
    if (raw is! String) return null;
    for (final model in RiscvReferenceModel.values) {
      if (model.wireName == raw) return model;
    }
    return null;
  }

  /// Every model token, in declaration order.
  static List<String> get wireNames =>
      RiscvReferenceModel.values.map((m) => m.wireName).toList();
}
