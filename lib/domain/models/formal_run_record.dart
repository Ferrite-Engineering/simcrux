// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

/// One formal result row as the trend store keeps it (`formal_runs`, with its
/// properties in `formal_properties` and `formal_property_results`), keyed by
/// the run and test the result row has.
///
/// The verdict is the stored token, verbatim: a reader parses it with
/// `FormalVerdict.fromWireName` and lands an unreadable one in Unrecognised,
/// never in Proved.
@immutable
class FormalRunRecord {
  /// Creates the record.
  FormalRunRecord({
    required this.runId,
    required this.testId,
    required this.tool,
    required this.verdict,
    this.task,
    this.mode,
    this.depthConfigured,
    this.depthReached,
    this.wallTimeMs,
    this.wallTimeSource,
    this.engine,
    this.solver,
    this.frontend,
    this.propertyCount,
    this.propertiesFailed,
    this.propertiesUndecided,
    this.verdictDisagreement = false,
    this.startedAt,
    List<FormalPropertyRecord> properties = const <FormalPropertyRecord>[],
  }) : properties = List<FormalPropertyRecord>.unmodifiable(properties);

  /// `runs.id`.
  final String runId;

  /// `test_results.test_name`.
  final String testId;

  /// `sby`, `eqy` or `riscv_formal`.
  final String tool;

  /// The `[tasks]` name, when there is one.
  final String? task;

  /// `bmc`, `prove`, `cover`, `live` or `equiv`.
  final String? mode;

  /// The stored verdict token.
  final String verdict;

  /// The configured bound.
  final int? depthConfigured;

  /// The deepest step the log reported, zero-based.
  final int? depthReached;

  /// Wall time in milliseconds.
  final int? wallTimeMs;

  /// `engine` or `measured`.
  final String? wallTimeSource;

  /// The engine word (`smtbmc`).
  final String? engine;

  /// The rest of the engine line (`yices`).
  final String? solver;

  /// `builtin`, `slang`, `verific` or `unknown`.
  final String? frontend;

  /// How many properties the task checked.
  final int? propertyCount;

  /// Properties that ended as a counterexample or unreached.
  final int? propertiesFailed;

  /// Properties that ended undecided or did not run.
  final int? propertiesUndecided;

  /// Whether the task verdict and the per-property statuses disagreed.
  final bool verdictDisagreement;

  /// When the run started, read back from `runs.started_at`; null on a
  /// record being written.
  final DateTime? startedAt;

  /// The task's properties, in run order.
  final List<FormalPropertyRecord> properties;
}

/// One property of one [FormalRunRecord].
@immutable
class FormalPropertyRecord {
  /// Creates the record.
  const FormalPropertyRecord({
    required this.propertyKey,
    required this.keyScheme,
    required this.kind,
    required this.location,
    required this.status,
    this.task,
    this.label,
    this.steps,
    this.tracePath,
    this.pretraceExposed = false,
  });

  /// [keyScheme] for a property keyed on the label the frontend kept.
  static const String kSchemeLabel = 'label';

  /// [keyScheme] for a property keyed on its `crux-fnv1a64/1` signature.
  static const String kSchemeSignature = 'signature';

  /// [keyScheme] for a RISC-V check, keyed on its check name.
  static const String kSchemeCheck = 'check';

  /// [keyScheme] for a property with no label and no readable source,
  /// keyed on its kind and location: its history splits when a line above
  /// it moves.
  static const String kSchemeLocation = 'location';

  /// The property's identity across runs within its test.
  final String propertyKey;

  /// Which identity [propertyKey] is.
  final String keyScheme;

  /// `assert`, `assume`, `cover`, `live` or `partition`.
  final String kind;

  /// The `[tasks]` name.
  final String? task;

  /// The user's label, when the frontend kept one.
  final String? label;

  /// `file:line[:col]`, project-relative: the identity within one run.
  final String location;

  /// The per-property status token (`proved`, `reached`, `counterexample`,
  /// `not_reached`, `inconclusive`, `did_not_run`), verbatim.
  final String status;

  /// The trace length, or the bound a held property reached.
  final int? steps;

  /// The counterexample or witness, relative to the task directory.
  final String? tracePath;

  /// Whether the result depends on state before the trace began.
  final bool pretraceExposed;
}
