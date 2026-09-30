// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// Format policy applied when comparing a DUT output file against a
/// golden reference file.
///
/// The `golden_compare` detector is deliberately **architecture
/// neutral** — comparing a device's output against a committed golden
/// and reporting the first divergent word is standard practice in DSP,
/// video, crypto and codec verification, not a RISC-V idea. The profile
/// is where the domain-specific knowledge lives: it selects the word
/// normalization policy and the conventional filenames, and nothing
/// else in the detector knows about any particular ISA or codec.
///
/// Adding a profile means adding a normalization policy plus its
/// defaults here; it must never mean adding a branch to the comparison
/// itself.
enum GoldenCompareProfile {
  /// No format folding: words are compared exactly as dumped.
  ///
  /// Whitespace is still insignificant (any run of spaces, tabs, `\r` or
  /// `\n` separates words, so CRLF files and blank lines compare equal),
  /// but case and prefixes are **not** folded — `DEADBEEF` and
  /// `deadbeef` are different words. This is the safe default: a
  /// bit-exact golden should not silently tolerate re-spelling.
  ///
  /// Has no conventional filenames, so `dut:` and `reference:` must be
  /// given explicitly.
  generic('generic'),

  /// RISC-V architectural-test signature dumps.
  ///
  /// A signature dump is the memory region a `riscv-arch-test` test
  /// writes between its `begin_signature` / `end_signature` labels,
  /// emitted one hex word per line. Reference models and target plugins
  /// disagree about spelling, so this profile folds case and an optional
  /// `0x` / `0X` prefix. Leading zeros are **not** stripped: signature
  /// words are fixed width, so `0000dead` and `dead` are genuinely
  /// different words and equating them would hide a real divergence.
  ///
  /// Supplies the conventional filenames used by the `riscv:` block's
  /// `signature:` defaults, so `type: golden_compare` +
  /// `profile: riscv_signature` needs no paths.
  riscvSignature('riscv_signature');

  const GoldenCompareProfile(this.wireName);

  /// Stable token used in `simcrux.yaml` and in the settings store.
  /// Never localize or reformat this — it lands in user config files.
  final String wireName;

  /// Conventional DUT filename for this profile, or null when the
  /// profile has no convention and the path must be given explicitly.
  String? get defaultDutPath => switch (this) {
    GoldenCompareProfile.generic => null,
    GoldenCompareProfile.riscvSignature => 'signature.dut.sig',
  };

  /// Conventional reference filename for this profile, or null when the
  /// path must be given explicitly.
  String? get defaultReferencePath => switch (this) {
    GoldenCompareProfile.generic => null,
    GoldenCompareProfile.riscvSignature => 'signature.ref.sig',
  };

  /// Parses a [wireName] back to its enum value, or null when the token
  /// is unknown.
  static GoldenCompareProfile? fromWireName(Object? raw) {
    if (raw is! String) return null;
    for (final profile in GoldenCompareProfile.values) {
      if (profile.wireName == raw) return profile;
    }
    return null;
  }

  /// Every profile token, in declaration order — used to render loader
  /// diagnostics that enumerate the valid values.
  static List<String> get wireNames =>
      GoldenCompareProfile.values.map((p) => p.wireName).toList();
}
