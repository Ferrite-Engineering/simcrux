// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/domain/enums/golden_compare_profile.dart';

/// Strategy used to classify a test run's pass/fail status.
///
/// Sealed-style hierarchy with one variant per detector type. The
/// concrete `PassFailDetector` implementation switches on the variant
/// at runtime. Variants: `exitCode`, `stringMatch`, `regex`,
/// `composite`, `uvmReport`, `cocotbXml`, and `goldenCompare` for
/// golden-file comparison.
@immutable
sealed class PassFailConfig {
  /// Const default constructor.
  const PassFailConfig();
}

/// Pass if and only if the simulator process exits with code 0.
@immutable
class ExitCodePassFailConfig extends PassFailConfig {
  /// Const constructor.
  const ExitCodePassFailConfig();

  @override
  bool operator ==(Object other) => other is ExitCodePassFailConfig;

  @override
  int get hashCode => (ExitCodePassFailConfig).hashCode;
}

/// Pass / fail based on whether one or more substrings appear in
/// stdout / stderr.
@immutable
class StringMatchPassFailConfig extends PassFailConfig {
  /// Creates a string-match config. At least one of [passString] or
  /// [failString] must be non-null.
  const StringMatchPassFailConfig({this.passString, this.failString})
    : assert(
        passString != null || failString != null,
        'At least one of passString / failString must be provided.',
      );

  /// If non-null, presence of this substring marks the test as pass.
  final String? passString;

  /// If non-null, presence of this substring marks the test as fail.
  /// Wins over [passString] when both fire (a fail string is always
  /// fatal).
  final String? failString;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is StringMatchPassFailConfig &&
        other.passString == passString &&
        other.failString == failString;
  }

  @override
  int get hashCode => Object.hash(passString, failString);
}

/// Pass / fail based on a regular expression match against stdout /
/// stderr. Same semantics as `StringMatchPassFailConfig` but with
/// regex matching.
@immutable
class RegexPassFailConfig extends PassFailConfig {
  /// Creates a regex-match config. At least one of [passPattern] or
  /// [failPattern] must be non-null.
  const RegexPassFailConfig({this.passPattern, this.failPattern})
    : assert(
        passPattern != null || failPattern != null,
        'At least one of passPattern / failPattern must be provided.',
      );

  /// If non-null, a match against this pattern marks the test as
  /// pass.
  final String? passPattern;

  /// If non-null, a match against this pattern marks the test as
  /// fail. Wins over [passPattern] when both fire.
  final String? failPattern;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is RegexPassFailConfig &&
        other.passPattern == passPattern &&
        other.failPattern == failPattern;
  }

  @override
  int get hashCode => Object.hash(passPattern, failPattern);
}

/// Pass / fail based on a UVM report summary parsed from the
/// simulator's stdout. Counts `UVM_FATAL` / `UVM_ERROR` /
/// `UVM_WARNING` / `UVM_INFO` occurrences (either from per-message
/// lines or from the `--- UVM Report Summary ---` table) and fails
/// when the configured thresholds are crossed.
///
/// Both thresholds default to 1: any `UVM_FATAL` and any `UVM_ERROR`
/// fail the test. The defaults match commercial UVM-aware regression
/// managers (Verdi, Questa).
@immutable
class UvmReportPassFailConfig extends PassFailConfig {
  /// Creates a [UvmReportPassFailConfig].
  const UvmReportPassFailConfig({
    this.fatalThreshold = 1,
    this.errorThreshold = 1,
    this.warningThreshold,
  }) : assert(fatalThreshold >= 0, 'fatalThreshold must be >= 0'),
       assert(errorThreshold >= 0, 'errorThreshold must be >= 0');

  /// Number of `UVM_FATAL` messages that triggers a fail. The
  /// default `1` means "any fatal at all". Set to `0` to disable the
  /// fatal-threshold check (then the detector only looks at errors /
  /// warnings).
  final int fatalThreshold;

  /// Number of `UVM_ERROR` messages that triggers a fail. The
  /// default `1` means "any error at all". Set to `0` to disable
  /// the error-threshold check.
  final int errorThreshold;

  /// Optional warning threshold. When null (default), warnings are
  /// surfaced in the metrics but never trigger a fail — matching
  /// commercial-tool convention. When set to N, the detector fails
  /// the test once N warnings appear.
  final int? warningThreshold;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is UvmReportPassFailConfig &&
        other.fatalThreshold == fatalThreshold &&
        other.errorThreshold == errorThreshold &&
        other.warningThreshold == warningThreshold;
  }

  @override
  int get hashCode =>
      Object.hash(fatalThreshold, errorThreshold, warningThreshold);
}

/// Pass / fail from Cocotb's end-of-run summary line.
///
/// The YAML `type: cocotb`. Reads the aggregate Cocotb prints at the end of
/// every run:
///
///     ** TESTS=4 PASS=2 FAIL=1 SKIP=1 **
///     ** TESTS=4 PASS=1 FAIL=1 SKIP=1 XFAIL=1 **   (2.1, COCOTB_PREVIEW)
///
/// **This is not the same source the Cocotb *driver* uses**, and the
/// difference is deliberate rather than an oversight. `PassFailDetector.detect`
/// is a pure function of stdout, stderr, exit code and runtime — it is handed
/// no working directory — so a detector cannot open the `results.xml` the
/// driver prefers. The summary line is the richest signal available on this
/// interface, and it is enough to classify.
///
/// So: leave pass/fail to the driver when the Cocotb driver is running the
/// test — it already reads the report and needs no configuration. Reach for
/// this detector when you want the classification written down explicitly, or
/// composed with another rule, or when Cocotb output arrives through a runner
/// that is not the Cocotb driver.
class CocotbPassFailConfig extends PassFailConfig {
  /// Creates a [CocotbPassFailConfig].
  const CocotbPassFailConfig({this.allowNoTests = false});

  /// Whether a run that reports `TESTS=0` counts as a pass.
  ///
  /// Defaults to `false`: a regression that executed nothing is not a success,
  /// and silently passing an empty run is how a broken test filter goes
  /// unnoticed for weeks. Set `true` when a suite is legitimately allowed to
  /// select no tests.
  final bool allowNoTests;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CocotbPassFailConfig && other.allowNoTests == allowNoTests;
  }

  @override
  int get hashCode => allowNoTests.hashCode;
}

/// Pass / fail by comparing a DUT output dump against a committed
/// golden reference dump, word for word, reporting the first divergent
/// word and its offset.
///
/// The seventh YAML `type:` value (`golden_compare`) and the fifth
/// detector class. Deliberately **architecture neutral**: comparing an
/// output against a golden and locating the first divergence is standard
/// practice in DSP, video, crypto and codec verification as much as in
/// processor verification. RISC-V architectural signatures are the
/// flagship use, expressed as a [profile] rather than as the type.
///
/// Unlike every other variant this one is **classified from the
/// filesystem**, not from stdout / stderr — the dumps live in the test's
/// working directory. It is therefore reachable only through
/// `PassFailDetectorRegistry.classifyAsync`, which threads the working
/// directory in; the synchronous `classify` path throws rather than
/// degrading to `TestStatus.unknown`, because an unknown verdict would let
/// a missing dump pass silently.
///
/// Both paths resolve relative to the test's working directory when
/// relative, and are used as-is when absolute — so a golden committed
/// alongside the RTL can be named directly.
///
/// The compatibility verdict this variant produces is **open core and is
/// never tier-gated**, including after `kBetaPeriod` flips: a
/// compatibility verdict is correctness, and correctness is free. Do
/// not add a `FeatureGate` or a `LicenseTier` check to this variant, its
/// detector, or its loader path.
@immutable
class GoldenComparePassFailConfig extends PassFailConfig {
  /// Creates a [GoldenComparePassFailConfig].
  const GoldenComparePassFailConfig({
    required this.dutPath,
    required this.referencePath,
    this.profile = GoldenCompareProfile.generic,
  });

  /// Creates a config for [profile] using its conventional filenames.
  ///
  /// Throws [ArgumentError] for a profile that has no conventional
  /// filenames (`generic`), where the paths must be given explicitly.
  factory GoldenComparePassFailConfig.forProfile(
    GoldenCompareProfile profile,
  ) {
    final dut = profile.defaultDutPath;
    final ref = profile.defaultReferencePath;
    if (dut == null || ref == null) {
      throw ArgumentError.value(
        profile,
        'profile',
        'has no conventional filenames; pass dutPath / referencePath',
      );
    }
    return GoldenComparePassFailConfig(
      dutPath: dut,
      referencePath: ref,
      profile: profile,
    );
  }

  /// Path to the dump produced by the design under test. Relative paths
  /// resolve against the test's working directory.
  final String dutPath;

  /// Path to the golden reference dump. Relative paths resolve against
  /// the test's working directory; an absolute path lets a committed
  /// golden live outside the run tree.
  final String referencePath;

  /// Word-normalization policy. The only domain-specific knob; the
  /// comparison itself is format agnostic.
  final GoldenCompareProfile profile;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is GoldenComparePassFailConfig &&
        other.dutPath == dutPath &&
        other.referencePath == referencePath &&
        other.profile == profile;
  }

  @override
  int get hashCode => Object.hash(dutPath, referencePath, profile);
}

/// Combine boolean-logic of multiple detectors. `allOf` is AND;
/// `anyOf` is OR. At least one of the lists must be non-empty.
@immutable
class CompositePassFailConfig extends PassFailConfig {
  /// Creates a composite config.
  CompositePassFailConfig({
    List<PassFailConfig>? allOf,
    List<PassFailConfig>? anyOf,
  }) : allOf = List<PassFailConfig>.unmodifiable(allOf ?? const []),
       anyOf = List<PassFailConfig>.unmodifiable(anyOf ?? const []),
       assert(
         (allOf != null && allOf.isNotEmpty) ||
             (anyOf != null && anyOf.isNotEmpty),
         'At least one of allOf / anyOf must be non-empty.',
       );

  /// Every child detector must report pass.
  final List<PassFailConfig> allOf;

  /// At least one child detector must report pass.
  final List<PassFailConfig> anyOf;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! CompositePassFailConfig) return false;
    if (allOf.length != other.allOf.length) return false;
    if (anyOf.length != other.anyOf.length) return false;
    for (var i = 0; i < allOf.length; i++) {
      if (allOf[i] != other.allOf[i]) return false;
    }
    for (var i = 0; i < anyOf.length; i++) {
      if (anyOf[i] != other.anyOf[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    Object.hashAll(allOf),
    Object.hashAll(anyOf),
  );
}
