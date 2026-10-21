// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

/// The upstream work that would remove the unsupported-SVA diagnostic,
/// shown in its explanation. A configuration value: updated in a patch when
/// the upstream status changes, and never translated.
const String kSvaUpstreamReference = 'yosys-slang pull request 317';

/// The frontend that read a formal job's design.
///
/// Measured per run: from the frontend banner in the task's Yosys log
/// (`Executing Verilog-2005 frontend`, `Executing SLANG frontend`,
/// `Executing VERIFIC`) and, when that log is absent, from the `.sby`
/// `[script]` (`read_verilog -formal`, `read_slang`, `verific -sv`).
enum FormalFrontend {
  /// Yosys's own Verilog frontend (`read_verilog -formal`, `read -formal`).
  builtin('builtin'),

  /// The yosys-slang plugin (`read_slang`).
  slang('slang'),

  /// The Verific frontend of a commercial Yosys build (`verific -sv`).
  verific('verific'),

  /// Not determined.
  unknown('unknown');

  const FormalFrontend(this.wireName);

  /// Stable token, stored in `formal.frontend` and sent in telemetry.
  final String wireName;

  /// The frontend for a stored token, or null.
  static FormalFrontend? fromWireName(Object? token) {
    for (final value in values) {
      if (value.wireName == token) return value;
    }
    return null;
  }
}

/// The closed construct classes an SVA refusal is reported in.
///
/// The class is SimCrux's vocabulary, never the user's text, so it may be
/// stored, shown and counted. The construct itself (`|=>`, `##[1:3]`) is
/// shown but never counted.
enum SvaConstructClass {
  /// `|->`, `|=>`: an implication across cycles.
  implication('implication'),

  /// `##1`, `##[1:3]`, `nexttime`: a cycle delay.
  delay('delay'),

  /// `[*2]`, `[->1]`, `[=1]`: a repetition.
  repetition('repetition'),

  /// `throughout`, `until`, `within`, `intersect`, sequence `and`/`or`.
  sequenceOp('sequence_op'),

  /// `sequence … endsequence`, `property … endproperty`.
  namedSequence('named_sequence'),

  /// `default clocking`, `default disable iff`.
  defaultClocking('default_clocking'),

  /// `s_eventually`, `eventually`, `strong`, `s_until`, `s_nexttime`.
  livenessOp('liveness_op'),

  /// Any other assertion form the frontend refused.
  other('other');

  const SvaConstructClass(this.wireName);

  /// Stable token. Never localize it.
  final String wireName;

  /// The class for a stored token, or null.
  static SvaConstructClass? fromWireName(Object? token) {
    for (final value in values) {
      if (value.wireName == token) return value;
    }
    return null;
  }

  /// True for the classes that are temporal SVA (every class but [other]).
  bool get temporal => this != SvaConstructClass.other;
}

/// Why SimCrux knows a formal row did not run, beyond the engine's own
/// `ERROR`.
enum FormalNotRunReason {
  /// The frontend refused an SVA construct ([SvaConstructClass]).
  svaUnsupported('sva_unsupported'),

  /// The frontend accepted the source, but no property of the kind the
  /// mode checks reached the elaborated design: it was dropped.
  dropped('dropped');

  const FormalNotRunReason(this.wireName);

  /// Stable token, stored in `formal.not_run_reason`.
  final String wireName;

  /// The reason for a stored token, or null.
  static FormalNotRunReason? fromWireName(Object? token) {
    for (final value in values) {
      if (value.wireName == token) return value;
    }
    return null;
  }
}

/// A frontend's refusal of an SVA construct, classified.
@immutable
class SvaRefusal {
  /// Creates a refusal.
  const SvaRefusal({
    required this.constructClass,
    required this.frontend,
    this.construct,
    this.file,
    this.line,
  });

  /// The closed class.
  final SvaConstructClass constructClass;

  /// The frontend that refused it.
  final FormalFrontend frontend;

  /// The construct as written (`|=>`, `##[1:3]`, `sequence`), or null when
  /// the source could not be read.
  final String? construct;

  /// The file the frontend named, as it spelled it.
  final String? file;

  /// The line the frontend named.
  final int? line;

  /// `file:line`, or null without a file.
  String? get location =>
      file == null ? null : (line == null ? file : '$file:$line');

  @override
  bool operator ==(Object other) =>
      other is SvaRefusal &&
      other.constructClass == constructClass &&
      other.frontend == frontend &&
      other.construct == construct &&
      other.file == file &&
      other.line == line;

  @override
  int get hashCode =>
      Object.hash(constructClass, frontend, construct, file, line);

  @override
  String toString() =>
      'SvaRefusal(${constructClass.wireName}, ${frontend.wireName}, '
      '$construct at $location)';
}

/// A property whose result depends on state from before the trace began:
/// a `$past` chain of [depth] registers feeds it, and it fired at [step],
/// before the chain had filled.
@immutable
class FormalPretraceMarker {
  /// Creates a marker.
  const FormalPretraceMarker({
    required this.kind,
    required this.depth,
    required this.step,
    this.location,
  });

  /// `assert` or `cover`.
  final String kind;

  /// The deepest `$past` chain feeding the property.
  final int depth;

  /// The step `sby` reported the property at.
  final int step;

  /// The property's location, as shown on the row.
  final String? location;

  @override
  bool operator ==(Object other) =>
      other is FormalPretraceMarker &&
      other.kind == kind &&
      other.depth == depth &&
      other.step == step &&
      other.location == location;

  @override
  int get hashCode => Object.hash(kind, depth, step, location);

  @override
  String toString() =>
      'FormalPretraceMarker($kind, depth $depth, step $step, $location)';
}
