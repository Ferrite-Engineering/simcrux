// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/interfaces/pr_annotation_dispatcher.dart';
import 'package:simcrux/domain/models/pr_annotation.dart';
import 'package:simcrux/domain/models/pr_annotation_dispatch_result.dart';
import 'package:simcrux/domain/models/pr_annotation_target.dart';
import 'package:simcrux/services/pr_annotation/pr_annotation_dispatcher_provider.dart';

class _RecordingDispatcher implements PrAnnotationDispatcher {
  final List<List<PrAnnotation>> batches = [];
  @override
  Future<PrAnnotationBatchResult> dispatch(
    List<PrAnnotation> annotations,
    PrAnnotationTarget target,
  ) async {
    batches.add(annotations);
    return PrAnnotationBatchResult(
      entries: annotations
          .map(
            (a) => PrAnnotationDispatchResult(
              annotation: a,
              outcome: PrAnnotationDispatchOutcome.success,
              statusCode: 201,
            ),
          )
          .toList(),
    );
  }

  @override
  Stream<PrAnnotationProgress> get progress =>
      const Stream<PrAnnotationProgress>.empty();
}

void main() {
  group('prAnnotationDispatcherProvider', () {
    test('open-core default is NoopPrAnnotationDispatcher', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        container.read(prAnnotationDispatcherProvider),
        isA<NoopPrAnnotationDispatcher>(),
      );
    });

    test(
      'noop dispatcher returns empty batch result + empty progress stream',
      () async {
        const dispatcher = NoopPrAnnotationDispatcher();
        final ann = PrAnnotation(
          targetKind: PrAnnotationTargetKind.annotation,
          severity: PrAnnotationSeverity.error,
          title: 't',
          message: 'm',
        );
        const target = PrAnnotationTarget(
          platform: PrAnnotationPlatform.github,
          repositoryRef: 'r',
          prNumber: 1,
          authToken: 'abc',
        );
        final result = await dispatcher.dispatch([ann], target);
        expect(result.entries, isEmpty);
        expect(result.isEmpty, isTrue);
        expect(result.allSucceeded, isFalse);
        expect(await dispatcher.progress.toList(), isEmpty);
      },
    );

    test('override surfaces the supplied dispatcher', () async {
      final recording = _RecordingDispatcher();
      final container = ProviderContainer(
        overrides: [
          prAnnotationDispatcherProvider.overrideWithValue(recording),
        ],
      );
      addTearDown(container.dispose);
      final dispatcher = container.read(prAnnotationDispatcherProvider);
      final ann = PrAnnotation(
        targetKind: PrAnnotationTargetKind.annotation,
        severity: PrAnnotationSeverity.error,
        title: 't',
        message: 'm',
      );
      const target = PrAnnotationTarget(
        platform: PrAnnotationPlatform.webhook,
        webhookUrl: 'https://example.com',
      );
      final result = await dispatcher.dispatch([ann], target);
      expect(result.successCount, 1);
      expect(result.allSucceeded, isTrue);
      expect(recording.batches.single, [ann]);
    });
  });

  group('PrAnnotationBatchResult', () {
    test('counts successes / failures correctly across mixed outcomes', () {
      final ann = PrAnnotation(
        targetKind: PrAnnotationTargetKind.annotation,
        severity: PrAnnotationSeverity.error,
        title: 't',
        message: 'm',
      );
      final batch = PrAnnotationBatchResult(
        entries: [
          PrAnnotationDispatchResult(
            annotation: ann,
            outcome: PrAnnotationDispatchOutcome.success,
            statusCode: 201,
          ),
          PrAnnotationDispatchResult(
            annotation: ann,
            outcome: PrAnnotationDispatchOutcome.rateLimited,
            statusCode: 429,
          ),
          PrAnnotationDispatchResult(
            annotation: ann,
            outcome: PrAnnotationDispatchOutcome.networkError,
            errorMessage: 'timeout',
          ),
        ],
      );
      expect(batch.successCount, 1);
      expect(batch.failureCount, 2);
      expect(batch.allSucceeded, isFalse);
    });

    test('zero-entry batch reports isEmpty=true, allSucceeded=false', () {
      final batch = PrAnnotationBatchResult(entries: const []);
      expect(batch.isEmpty, isTrue);
      expect(batch.allSucceeded, isFalse);
    });
  });

  group('PrAnnotationProgress', () {
    test('fraction clamps to [0, 1]', () {
      final ann = PrAnnotation(
        targetKind: PrAnnotationTargetKind.annotation,
        severity: PrAnnotationSeverity.error,
        title: 't',
        message: 'm',
      );
      final r = PrAnnotationDispatchResult(
        annotation: ann,
        outcome: PrAnnotationDispatchOutcome.success,
      );
      expect(
        PrAnnotationProgress(completed: 0, total: 10, lastResult: r).fraction,
        0.0,
      );
      expect(
        PrAnnotationProgress(completed: 5, total: 10, lastResult: r).fraction,
        0.5,
      );
      expect(
        PrAnnotationProgress(completed: 10, total: 10, lastResult: r).fraction,
        1.0,
      );
      // Total=0 is the empty batch — fraction is 0 by convention.
      expect(
        PrAnnotationProgress(completed: 0, total: 0, lastResult: r).fraction,
        0.0,
      );
    });
  });
}
