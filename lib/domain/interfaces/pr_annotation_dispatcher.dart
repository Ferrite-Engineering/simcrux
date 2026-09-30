// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/domain/models/pr_annotation.dart';
import 'package:simcrux/domain/models/pr_annotation_dispatch_result.dart';
import 'package:simcrux/domain/models/pr_annotation_target.dart';

/// Strategy interface for posting a batch of [PrAnnotation]s to a
/// PR / MR / webhook target.
///
/// **Open-core default.** `NoopPrAnnotationDispatcher` returns an
/// empty [PrAnnotationBatchResult] for every call — open-core
/// builds never post anywhere because the per-platform HTTP
/// implementations live in the Pro overlay.
///
/// **Pro override.** The Pro overlay's `proOverrides` list registers
/// a dispatcher per platform (`PrAnnotationPlatform.github` →
/// `GitHubPrAnnotationDispatcher`, etc.). When more than one Pro
/// dispatcher is loaded, the active one is selected by the user's
/// Settings → PR Annotation target choice.
///
/// **Failure modes.** Every annotation has a per-entry outcome in
/// the [PrAnnotationBatchResult]; the dispatcher does not throw on
/// dispatch failure. Auth failures (401 / 403) abort the rest of
/// the batch with [PrAnnotationDispatchOutcome.authFailed] on every
/// remaining entry — there's no value in continuing if the token
/// is rejected. Rate-limit / network errors are first-class
/// outcomes the dispatcher records but does not raise.
///
/// **Progress stream.** [progress] emits per-annotation as long
/// batches run. Implementations that don't track progress (e.g.
/// the noop default) can return [Stream.empty()] — callers must
/// tolerate streams that emit zero events.
abstract class PrAnnotationDispatcher {
  /// Dispatches [annotations] against [target]. Returns when every
  /// annotation has been attempted (or aborted on auth failure).
  Future<PrAnnotationBatchResult> dispatch(
    List<PrAnnotation> annotations,
    PrAnnotationTarget target,
  );

  /// Per-annotation progress events for the most recent / active
  /// batch. Optional; implementations that don't track progress
  /// return [Stream.empty()].
  Stream<PrAnnotationProgress> get progress;
}

/// Default [PrAnnotationDispatcher] registered against
/// [prAnnotationDispatcherProvider] in open-core builds. Returns an
/// empty batch result and an empty progress stream — feature code
/// can call `dispatch` unconditionally and get a sane no-op when
/// the Pro overlay isn't loaded.
class NoopPrAnnotationDispatcher implements PrAnnotationDispatcher {
  /// Const default.
  const NoopPrAnnotationDispatcher();

  @override
  Future<PrAnnotationBatchResult> dispatch(
    List<PrAnnotation> annotations,
    PrAnnotationTarget target,
  ) async {
    return PrAnnotationBatchResult(entries: const []);
  }

  @override
  Stream<PrAnnotationProgress> get progress =>
      const Stream<PrAnnotationProgress>.empty();
}
