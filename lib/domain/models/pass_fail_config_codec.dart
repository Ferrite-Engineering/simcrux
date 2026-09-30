// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:simcrux/domain/enums/golden_compare_profile.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';

/// Storage-layer representation of a pass/fail detector tree.
///
/// Distinct from [PassFailConfig] because it can carry an additional
/// variant — [UseSpec] — that references a reusable detector by
/// name. The runtime [PassFailConfig] hierarchy is sealed and cannot
/// carry references; resolution happens at the loader boundary
/// (config loader / settings UI).
///
/// Round-trippable to / from a JSON-shaped map. Encoding mirrors the
/// YAML schema in `simcrux.yaml`, so a storage entry can be lifted
/// verbatim into a `simcrux.yaml` `pass_fail:` block (and vice
/// versa).
@immutable
sealed class DetectorSpec {
  /// Const constructor.
  const DetectorSpec();

  /// Decodes a JSON-style map into a [DetectorSpec]. Returns null on
  /// malformed input so callers can fall back to a default detector.
  static DetectorSpec? decode(Object? json) {
    if (json is! Map) return null;
    final type = json['type'];
    if (type is! String) return null;
    switch (type) {
      case 'exit_code':
        return const ExitCodeSpec();
      case 'string_match':
        final pass = json['pass_string'];
        final fail = json['fail_string'];
        if (pass is! String && fail is! String) return null;
        return StringMatchSpec(
          passString: pass is String ? pass : null,
          failString: fail is String ? fail : null,
        );
      case 'regex':
        final pass = json['pass_pattern'];
        final fail = json['fail_pattern'];
        if (pass is! String && fail is! String) return null;
        return RegexSpec(
          passPattern: pass is String ? pass : null,
          failPattern: fail is String ? fail : null,
        );
      case 'uvm_report':
        final fatal = (json['fatal_threshold'] as num?)?.toInt() ?? 1;
        final error = (json['error_threshold'] as num?)?.toInt() ?? 1;
        final warn = (json['warning_threshold'] as num?)?.toInt();
        if (fatal < 0 || error < 0) return null;
        return UvmReportSpec(
          fatalThreshold: fatal,
          errorThreshold: error,
          warningThreshold: warn,
        );
      case 'cocotb':
        final allowNoTests = json['allow_no_tests'];
        return CocotbSpec(allowNoTests: allowNoTests == true);
      case 'golden_compare':
        final profile =
            GoldenCompareProfile.fromWireName(json['profile']) ??
            (json.containsKey('profile') ? null : GoldenCompareProfile.generic);
        if (profile == null) return null;
        final dut = json['dut'] is String
            ? json['dut'] as String
            : profile.defaultDutPath;
        final reference = json['reference'] is String
            ? json['reference'] as String
            : profile.defaultReferencePath;
        if (dut == null ||
            dut.isEmpty ||
            reference == null ||
            reference.isEmpty) {
          return null;
        }
        return GoldenCompareSpec(
          dutPath: dut,
          referencePath: reference,
          profile: profile,
        );
      case 'composite':
        final allOf = _decodeList(json['all_of']);
        final anyOf = _decodeList(json['any_of']);
        if (allOf.isEmpty && anyOf.isEmpty) return null;
        return CompositeSpec(allOf: allOf, anyOf: anyOf);
      case 'use':
        final name = json['name'];
        if (name is! String || name.isEmpty) return null;
        return UseSpec(name);
      default:
        return null;
    }
  }

  /// Encodes [spec] to a JSON-friendly map.
  static Map<String, Object?> encode(DetectorSpec spec) {
    switch (spec) {
      case ExitCodeSpec():
        return const {'type': 'exit_code'};
      case CocotbSpec(:final allowNoTests):
        return <String, Object?>{
          'type': 'cocotb',
          if (allowNoTests) 'allow_no_tests': true,
        };
      case StringMatchSpec(:final passString, :final failString):
        return <String, Object?>{
          'type': 'string_match',
          'pass_string': ?passString,
          'fail_string': ?failString,
        };
      case RegexSpec(:final passPattern, :final failPattern):
        return <String, Object?>{
          'type': 'regex',
          'pass_pattern': ?passPattern,
          'fail_pattern': ?failPattern,
        };
      case UvmReportSpec(
        :final fatalThreshold,
        :final errorThreshold,
        :final warningThreshold,
      ):
        return <String, Object?>{
          'type': 'uvm_report',
          'fatal_threshold': fatalThreshold,
          'error_threshold': errorThreshold,
          'warning_threshold': ?warningThreshold,
        };
      case GoldenCompareSpec(
        :final dutPath,
        :final referencePath,
        :final profile,
      ):
        return <String, Object?>{
          'type': 'golden_compare',
          'profile': profile.wireName,
          'dut': dutPath,
          'reference': referencePath,
        };
      case CompositeSpec(:final allOf, :final anyOf):
        return <String, Object?>{
          'type': 'composite',
          if (allOf.isNotEmpty)
            'all_of': allOf.map(encode).toList(growable: false),
          if (anyOf.isNotEmpty)
            'any_of': anyOf.map(encode).toList(growable: false),
        };
      case UseSpec(:final name):
        return <String, Object?>{'type': 'use', 'name': name};
    }
  }

  /// Round-trips a [DetectorSpec] to its JSON-string representation
  /// suitable for storage in `SharedPreferences`.
  static String encodeToString(DetectorSpec spec) => jsonEncode(encode(spec));

  /// Inverse of [encodeToString].
  static DetectorSpec? decodeFromString(String? text) {
    if (text == null || text.isEmpty) return null;
    try {
      return decode(jsonDecode(text));
    } on FormatException {
      return null;
    }
  }

  /// Resolves a [DetectorSpec] tree against a reusable-detector map,
  /// returning a [PassFailConfig] suitable for the runtime registry.
  /// `use` references are expanded inline; cycles raise [StateError].
  static PassFailConfig? resolve(
    DetectorSpec spec,
    Map<String, DetectorSpec> reusable, {
    Set<String>? visiting,
  }) {
    final stack = visiting ?? <String>{};
    switch (spec) {
      case ExitCodeSpec():
        return const ExitCodePassFailConfig();
      case CocotbSpec(:final allowNoTests):
        return CocotbPassFailConfig(allowNoTests: allowNoTests);
      case StringMatchSpec(:final passString, :final failString):
        if (passString == null && failString == null) return null;
        return StringMatchPassFailConfig(
          passString: passString,
          failString: failString,
        );
      case RegexSpec(:final passPattern, :final failPattern):
        if (passPattern == null && failPattern == null) return null;
        return RegexPassFailConfig(
          passPattern: passPattern,
          failPattern: failPattern,
        );
      case UvmReportSpec(
        :final fatalThreshold,
        :final errorThreshold,
        :final warningThreshold,
      ):
        return UvmReportPassFailConfig(
          fatalThreshold: fatalThreshold,
          errorThreshold: errorThreshold,
          warningThreshold: warningThreshold,
        );
      case GoldenCompareSpec(
        :final dutPath,
        :final referencePath,
        :final profile,
      ):
        if (dutPath.isEmpty || referencePath.isEmpty) return null;
        return GoldenComparePassFailConfig(
          dutPath: dutPath,
          referencePath: referencePath,
          profile: profile,
        );
      case CompositeSpec(:final allOf, :final anyOf):
        final allOfResolved = <PassFailConfig>[];
        final anyOfResolved = <PassFailConfig>[];
        for (final child in allOf) {
          final r = resolve(child, reusable, visiting: stack);
          if (r != null) allOfResolved.add(r);
        }
        for (final child in anyOf) {
          final r = resolve(child, reusable, visiting: stack);
          if (r != null) anyOfResolved.add(r);
        }
        if (allOfResolved.isEmpty && anyOfResolved.isEmpty) return null;
        return CompositePassFailConfig(
          allOf: allOfResolved,
          anyOf: anyOfResolved,
        );
      case UseSpec(:final name):
        if (stack.contains(name)) {
          throw StateError(
            'Detector reference cycle detected at "$name". Stack: $stack',
          );
        }
        final target = reusable[name];
        if (target == null) return null;
        stack.add(name);
        try {
          return resolve(target, reusable, visiting: stack);
        } finally {
          stack.remove(name);
        }
    }
  }

  static List<DetectorSpec> _decodeList(Object? raw) {
    if (raw is! List) return const <DetectorSpec>[];
    final out = <DetectorSpec>[];
    for (final entry in raw) {
      final child = decode(entry);
      if (child != null) out.add(child);
    }
    return out;
  }
}

/// Exit-code variant (matches [ExitCodePassFailConfig]).
class ExitCodeSpec extends DetectorSpec {
  /// Const constructor.
  const ExitCodeSpec();

  @override
  bool operator ==(Object other) => other is ExitCodeSpec;

  @override
  int get hashCode => (ExitCodeSpec).hashCode;
}

/// String-match variant.
class StringMatchSpec extends DetectorSpec {
  /// Const constructor.
  const StringMatchSpec({this.passString, this.failString});

  /// Pass-on-match substring.
  final String? passString;

  /// Fail-on-match substring.
  final String? failString;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StringMatchSpec &&
          other.passString == passString &&
          other.failString == failString;

  @override
  int get hashCode => Object.hash(passString, failString);
}

/// Regex-match variant.
class RegexSpec extends DetectorSpec {
  /// Const constructor.
  const RegexSpec({this.passPattern, this.failPattern});

  /// Pass-on-match regex.
  final String? passPattern;

  /// Fail-on-match regex.
  final String? failPattern;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RegexSpec &&
          other.passPattern == passPattern &&
          other.failPattern == failPattern;

  @override
  int get hashCode => Object.hash(passPattern, failPattern);
}

/// UVM-report variant.
class UvmReportSpec extends DetectorSpec {
  /// Const constructor.
  const UvmReportSpec({
    this.fatalThreshold = 1,
    this.errorThreshold = 1,
    this.warningThreshold,
  });

  /// Number of `UVM_FATAL` messages that triggers a fail.
  final int fatalThreshold;

  /// Number of `UVM_ERROR` messages that triggers a fail.
  final int errorThreshold;

  /// Optional warning threshold.
  final int? warningThreshold;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UvmReportSpec &&
          other.fatalThreshold == fatalThreshold &&
          other.errorThreshold == errorThreshold &&
          other.warningThreshold == warningThreshold;

  @override
  int get hashCode =>
      Object.hash(fatalThreshold, errorThreshold, warningThreshold);
}

/// Cocotb summary-line variant.
class CocotbSpec extends DetectorSpec {
  /// Const constructor.
  const CocotbSpec({this.allowNoTests = false});

  /// Whether `TESTS=0` counts as a pass. Defaults to false.
  final bool allowNoTests;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CocotbSpec && other.allowNoTests == allowNoTests;

  @override
  int get hashCode => allowNoTests.hashCode;
}

/// Golden-file comparison variant.
class GoldenCompareSpec extends DetectorSpec {
  /// Creates a [GoldenCompareSpec].
  const GoldenCompareSpec({
    required this.dutPath,
    required this.referencePath,
    this.profile = GoldenCompareProfile.generic,
  });

  /// Creates a spec seeded with [profile]'s conventional filenames.
  /// Throws [ArgumentError] for a profile without them.
  factory GoldenCompareSpec.forProfile(GoldenCompareProfile profile) {
    final dut = profile.defaultDutPath;
    final ref = profile.defaultReferencePath;
    if (dut == null || ref == null) {
      throw ArgumentError.value(
        profile,
        'profile',
        'has no conventional filenames; pass dutPath / referencePath',
      );
    }
    return GoldenCompareSpec(
      dutPath: dut,
      referencePath: ref,
      profile: profile,
    );
  }

  /// Path to the DUT's output dump.
  final String dutPath;

  /// Path to the golden reference dump.
  final String referencePath;

  /// Word-normalization policy.
  final GoldenCompareProfile profile;

  /// Returns a copy with the given fields replaced.
  GoldenCompareSpec copyWith({
    String? dutPath,
    String? referencePath,
    GoldenCompareProfile? profile,
  }) {
    return GoldenCompareSpec(
      dutPath: dutPath ?? this.dutPath,
      referencePath: referencePath ?? this.referencePath,
      profile: profile ?? this.profile,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GoldenCompareSpec &&
          other.dutPath == dutPath &&
          other.referencePath == referencePath &&
          other.profile == profile;

  @override
  int get hashCode => Object.hash(dutPath, referencePath, profile);
}

/// Composite (AND/OR) variant.
class CompositeSpec extends DetectorSpec {
  /// Creates a [CompositeSpec].
  CompositeSpec({
    List<DetectorSpec>? allOf,
    List<DetectorSpec>? anyOf,
  }) : allOf = List<DetectorSpec>.unmodifiable(allOf ?? const []),
       anyOf = List<DetectorSpec>.unmodifiable(anyOf ?? const []);

  /// Every child detector must report pass.
  final List<DetectorSpec> allOf;

  /// At least one child detector must report pass.
  final List<DetectorSpec> anyOf;

  /// Returns a copy with [allOf] / [anyOf] replaced.
  CompositeSpec copyWith({
    List<DetectorSpec>? allOf,
    List<DetectorSpec>? anyOf,
  }) {
    return CompositeSpec(
      allOf: allOf ?? this.allOf,
      anyOf: anyOf ?? this.anyOf,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! CompositeSpec) return false;
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
  int get hashCode => Object.hash(Object.hashAll(allOf), Object.hashAll(anyOf));
}

/// `use: <name>` reference. Resolved against the reusable-detector
/// store at config-load time.
class UseSpec extends DetectorSpec {
  /// Creates a [UseSpec].
  const UseSpec(this.name);

  /// Reusable-detector name.
  final String name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is UseSpec && other.name == name;

  @override
  int get hashCode => Object.hash(UseSpec, name);
}
