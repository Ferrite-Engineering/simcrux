// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/domain/enums/golden_compare_profile.dart';

/// Result of comparing a DUT output dump against a golden reference
/// dump.
///
/// Produced by [GoldenComparator.compare]. Pure data — no I/O, no
/// Flutter, no knowledge of where the two dumps came from.
///
/// Two consumers share this type:
///
/// - the **driver** (the `riscv_arch` driver, and any later one),
///   which calls the comparator and emits [toMetrics] on
///   `TestExecutionFinished.metrics`;
/// - the `golden_compare` **detector**, which calls the same comparator
///   and only classifies — a detector structurally cannot write metrics,
///   because `TestResult.metrics` is fed solely from
///   `TestExecutionFinished.metrics`.
///
/// Because both sides run the same comparison, the verdict and the offset
/// agree by construction.
@immutable
class GoldenComparison {
  /// Creates a [GoldenComparison]. Prefer [GoldenComparator.compare] over
  /// constructing this directly; the constructor is public so fixtures
  /// and tests can express an expectation.
  const GoldenComparison({
    required this.matched,
    required this.dutWords,
    required this.refWords,
    this.mismatchOffset,
    this.dutWord,
    this.refWord,
  });

  /// True only when both dumps hold the **same non-zero** number of words
  /// and every word compares equal under the active profile.
  ///
  /// Two empty dumps are deliberately **not** a match: an empty dump is
  /// "the run did not do the thing it was asked to do", not "nothing to
  /// check". Callers classify `matched == false` as a failure and
  /// must never map it to `unknown` or `vacuous`.
  final bool matched;

  /// Zero-based word index of the **first** divergence, or null when the
  /// dumps matched or when both were empty (nothing to point at).
  ///
  /// For a pure length divergence (one dump is a strict prefix of the
  /// other) this is the index at which the shorter dump ran out — i.e.
  /// `min(dutWords, refWords)`.
  final int? mismatchOffset;

  /// The DUT word at [mismatchOffset], **as dumped** (original spelling,
  /// before normalization). Null when the DUT dump has no word at that
  /// offset, or when there is no divergence.
  final String? dutWord;

  /// The reference word at [mismatchOffset], **as dumped**. Null when the
  /// reference dump has no word at that offset, or when there is no
  /// divergence.
  final String? refWord;

  /// Total number of words in the DUT dump.
  final int dutWords;

  /// Total number of words in the reference dump.
  final int refWords;

  /// True when the two dumps hold different word counts.
  bool get lengthMismatch => dutWords != refWords;

  /// True when the DUT dump contained no words at all.
  bool get dutEmpty => dutWords == 0;

  /// True when the reference dump contained no words at all.
  bool get refEmpty => refWords == 0;

  /// Renders the comparison as `TestResult.metrics` entries.
  ///
  /// **Only a driver may actually attach these** — see the class doc. The
  /// helper lives here so the reserved key spellings have exactly one
  /// definition and so the detector and the driver cannot drift.
  ///
  /// The word counts are always emitted, which is what lets a consumer
  /// tell a *content* divergence from a *length* divergence without
  /// re-reading files that retention may already have pruned. The offset
  /// and the two values are emitted only when there is a divergence to
  /// point at; the per-side value is omitted when that side has no word
  /// at the offset (the length-divergence case).
  Map<String, String> toMetrics() {
    final offset = mismatchOffset;
    return <String, String>{
      GoldenComparator.kMetricDutWords: '$dutWords',
      GoldenComparator.kMetricRefWords: '$refWords',
      if (offset != null) GoldenComparator.kMetricMismatchOffset: '$offset',
      GoldenComparator.kMetricDutValue: ?dutWord,
      GoldenComparator.kMetricRefValue: ?refWord,
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is GoldenComparison &&
        other.matched == matched &&
        other.mismatchOffset == mismatchOffset &&
        other.dutWord == dutWord &&
        other.refWord == refWord &&
        other.dutWords == dutWords &&
        other.refWords == refWords;
  }

  @override
  int get hashCode => Object.hash(
    matched,
    mismatchOffset,
    dutWord,
    refWord,
    dutWords,
    refWords,
  );

  @override
  String toString() =>
      'GoldenComparison(matched: $matched, offset: $mismatchOffset, '
      'dut: $dutWord, ref: $refWord, dutWords: $dutWords, '
      'refWords: $refWords)';
}

/// Pure, I/O-free comparison of a DUT output dump against a golden
/// reference dump.
///
/// "Compare my output against the committed golden and tell me the first
/// word that differs" is the same operation in DSP, video, crypto, codec
/// and processor verification. This class is that operation and nothing
/// else: it is architecture neutral, and the only domain knowledge in
/// play is the [GoldenCompareProfile] that selects a word-normalization
/// policy.
///
/// **Whitespace is always insignificant.** [tokenize] treats the file as
/// whitespace-separated words (any run of spaces / tabs / `\r` / `\n`),
/// so a one-word-per-line dump, a CRLF dump, and a dump padded with blank
/// lines all tokenize identically regardless of profile.
///
/// **Nothing here touches the filesystem.** The detector and the driver
/// each read their own files and hand the text in, which is what makes
/// this unit-testable against committed fixtures with no process and no
/// scheduler.
abstract final class GoldenComparator {
  /// Metric key for the zero-based word index of the first divergence.
  static const String kMetricMismatchOffset = 'golden.mismatch_offset';

  /// Metric key for the DUT word at the mismatch offset, as dumped.
  static const String kMetricDutValue = 'golden.dut_value';

  /// Metric key for the reference word at the mismatch offset, as dumped.
  static const String kMetricRefValue = 'golden.ref_value';

  /// Metric key for the DUT dump's total word count.
  static const String kMetricDutWords = 'golden.dut_words';

  /// Metric key for the reference dump's total word count.
  static const String kMetricRefWords = 'golden.ref_words';

  /// Every reserved `golden.*` metric key, in emission order.
  static const List<String> kMetricKeys = <String>[
    kMetricDutWords,
    kMetricRefWords,
    kMetricMismatchOffset,
    kMetricDutValue,
    kMetricRefValue,
  ];

  /// Splits a raw dump into its words, preserving each word's original
  /// spelling.
  ///
  /// Any run of whitespace separates words. A dump with no words at all
  /// yields an empty list.
  static List<String> tokenize(String raw) {
    final out = <String>[];
    for (final token in raw.split(RegExp(r'\s+'))) {
      if (token.isNotEmpty) out.add(token);
    }
    return List<String>.unmodifiable(out);
  }

  /// Folds a single word to its comparison form under [profile].
  ///
  /// [GoldenCompareProfile.generic] is the identity: bit-exact goldens
  /// should not silently tolerate re-spelling.
  /// [GoldenCompareProfile.riscvSignature] lowercases and drops an
  /// optional `0x` / `0X` prefix. A bare `0x` (prefix and nothing else)
  /// is left alone rather than folded to the empty string, so a malformed
  /// word stays visibly malformed instead of comparing equal to another
  /// malformed word.
  static String normalize(String word, GoldenCompareProfile profile) {
    switch (profile) {
      case GoldenCompareProfile.generic:
        return word;
      case GoldenCompareProfile.riscvSignature:
        final lower = word.toLowerCase();
        if (lower.length > 2 && lower.startsWith('0x')) {
          return lower.substring(2);
        }
        return lower;
    }
  }

  /// Compares a DUT dump against a reference dump under [profile].
  ///
  /// Returns the first divergence, if any:
  ///
  /// - **Match** — equal, non-zero word counts and every word equal after
  ///   [normalize].
  /// - **Word mismatch** — the lowest index at which the normalized words
  ///   differ, carrying both words as dumped.
  /// - **Length mismatch** — one dump is a strict prefix of the other;
  ///   the offset is where the shorter one ran out and only the longer
  ///   side carries a word.
  /// - **Empty** — either dump (or both) tokenized to zero words. Never a
  ///   match. When exactly one side is empty the offset is 0
  ///   and the non-empty side's first word is carried; when both are
  ///   empty there is no offset to report.
  static GoldenComparison compare({
    required String dut,
    required String reference,
    GoldenCompareProfile profile = GoldenCompareProfile.generic,
  }) {
    final dutTokens = tokenize(dut);
    final refTokens = tokenize(reference);
    final shorter = dutTokens.length < refTokens.length
        ? dutTokens.length
        : refTokens.length;

    for (var i = 0; i < shorter; i++) {
      if (normalize(dutTokens[i], profile) !=
          normalize(refTokens[i], profile)) {
        return GoldenComparison(
          matched: false,
          mismatchOffset: i,
          dutWord: dutTokens[i],
          refWord: refTokens[i],
          dutWords: dutTokens.length,
          refWords: refTokens.length,
        );
      }
    }

    if (dutTokens.length == refTokens.length) {
      // Equal length and no divergent word. Empty-vs-empty lands here and
      // must NOT be reported as a match: an empty dump is a failed run,
      // not a vacuous pass.
      if (dutTokens.isEmpty) {
        return const GoldenComparison(
          matched: false,
          dutWords: 0,
          refWords: 0,
        );
      }
      return GoldenComparison(
        matched: true,
        dutWords: dutTokens.length,
        refWords: refTokens.length,
      );
    }

    // The common prefix agreed but the dumps are different lengths. Point
    // at the index where the shorter one ran out.
    return GoldenComparison(
      matched: false,
      mismatchOffset: shorter,
      dutWord: shorter < dutTokens.length ? dutTokens[shorter] : null,
      refWord: shorter < refTokens.length ? refTokens[shorter] : null,
      dutWords: dutTokens.length,
      refWords: refTokens.length,
    );
  }
}
