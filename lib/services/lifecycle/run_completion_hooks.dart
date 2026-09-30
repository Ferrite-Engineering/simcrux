// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';
import 'package:simcrux/domain/models/test_result.dart';

/// What a [RunCompletionHook] is handed when a regression finishes.
class RunCompletionContext {
  /// Creates a context.
  const RunCompletionContext({
    required this.runId,
    required this.results,
    required this.cancelled,
    this.rows = const <CompletedResult>[],
  });

  /// The finished run's id.
  final String runId;

  /// Every result recorded during the run, in completion order.
  final List<TestResult> results;

  /// The same results, each paired with the suite and simulator it was
  /// recorded under.
  ///
  /// **Why this exists alongside [results].** A `TestResult` does not carry
  /// its suite or its simulator — those are properties of the `TestSpec` that
  /// produced it, held by the result store rather than by the result. A hook
  /// that writes a durable record of the run needs them, because a run
  /// archive without a suite or a simulator cannot answer the questions a run
  /// archive exists to answer.
  ///
  /// Defaulted to empty rather than required so that every existing hook and
  /// every test constructing a context keeps compiling; a hook that needs the
  /// metadata reads this, and one that does not carries on reading [results].
  final List<CompletedResult> rows;

  /// Whether the run was cancelled rather than running to completion.
  /// Hooks that report verdicts should treat a cancelled run as "no
  /// verdict", not as a failure.
  final bool cancelled;
}

/// One result, with the spec metadata the result itself does not carry.
@immutable
class CompletedResult {
  /// Creates a [CompletedResult].
  const CompletedResult({
    required this.result,
    this.suiteName,
    this.simulatorId,
  });

  /// The result.
  final TestResult result;

  /// The suite it was recorded under, or null when it was recorded without
  /// metadata — which is what the bare `recordResult` entry point does.
  final String? suiteName;

  /// The simulator it was recorded under. See [suiteName].
  final String? simulatorId;
}

/// A side effect to run when a regression finishes.
///
/// Hooks are awaited but **best-effort**: `RegressionRunner` catches and
/// swallows whatever a hook throws. A failing hook must never tear down
/// the completion of the run itself — the results are the product, and a
/// PR-annotation post that 500s is not a reason to lose them.
typedef RunCompletionHook = Future<void> Function(RunCompletionContext context);

/// Extension-point seam for post-run side effects.
///
/// **Open-core default:** empty. The Pro overlay appends the
/// PR-annotation auto-dispatch hook in `proOverrides`.
///
/// Existing post-run work in `RegressionRunner` (trend flush, retention
/// prune) is deliberately *not* expressed as hooks — those are ordered
/// with respect to each other and to the state publish, and turning them
/// into an unordered list would make that ordering implicit. Hooks are
/// for genuinely optional, order-independent side effects.
final Provider<List<RunCompletionHook>> runCompletionHooksProvider =
    Provider<List<RunCompletionHook>>((ref) => const <RunCompletionHook>[]);
