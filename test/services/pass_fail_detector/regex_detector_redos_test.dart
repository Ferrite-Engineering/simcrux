// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/services/pass_fail_detector/pass_fail_detector_registry.dart';
import 'package:simcrux/services/pass_fail_detector/regex_detector.dart';

/// ReDoS guard for [RegexDetector]. A user-authored pass/fail
/// pattern with catastrophic backtracking against a large simulator log
/// must not be able to hang the regression.
void main() {
  group('guardedRegexHasMatch — isolate deadline', () {
    test(
      'a catastrophic pattern on a 4 MB input returns under the deadline',
      () async {
        // `(a+)+\$` against ~4 MB of "a" terminated by "!" is the classic
        // exponential-backtracking bomb — it would hang a synchronous
        // RegExp.hasMatch indefinitely.
        final bomb = '${'a' * 4000000}!';
        final matched = await guardedRegexHasMatch(
          r'(a+)+$',
          bomb,
          deadline: const Duration(milliseconds: 500),
        );
        // The worker isolate is killed at the deadline and the guard
        // reports the safe default (no conclusive match) instead of
        // blocking forever.
        expect(matched, isFalse);
      },
      // If the guard fails to kill the isolate, the whole test hangs to
      // this bound — the mutation signal.
      timeout: const Timeout(Duration(seconds: 5)),
    );

    test('a normal pattern still matches well within the deadline', () async {
      final matched = await guardedRegexHasMatch(
        'UVM_ERROR',
        'sim start\nUVM_ERROR : 2 errors\n\$finish',
      );
      expect(matched, isTrue);
    });
  });

  // The scheduler classifies through `PassFailDetectorRegistry.classifyAsync`
  // → `RegexDetector.detectAsync`, so the deadline guard must hold on the
  // *production* path — not only the bare `guardedRegexHasMatch` helper the
  // unit tests above exercise. Before the async wiring, this path ran
  // `RegExp.hasMatch` synchronously on the calling isolate and a bomb here
  // would hang the whole regression.
  group('production classify path — deadline guard', () {
    // A catastrophic failPattern that would never terminate synchronously.
    // The scan bound alone does not cap backtracking time; only the isolate
    // deadline does. `maxScanChars` is left at its 1 MiB default so the
    // ~2 MB bomb is not truncated below the pathological size.
    final bomb = '${'a' * 2000000}!';

    test(
      'detectAsync returns under the deadline for a catastrophic failPattern',
      () async {
        const detector = RegexDetector();
        final status = await detector.detectAsync(
          stdout: bomb,
          stderr: '',
          exitCode: 0,
          runtime: Duration.zero,
          config: const RegexPassFailConfig(failPattern: r'(a+)+$'),
          deadline: const Duration(milliseconds: 500),
        );
        // On timeout the guard reports "no conclusive fail match", so the
        // fail branch does not fire and detection degrades to unknown
        // (scheduler then falls back to the exit-code default).
        expect(status, TestStatus.unknown);
      },
      timeout: const Timeout(Duration(seconds: 5)),
    );

    test(
      'classifyAsync returns under the deadline for a catastrophic pattern '
      'nested in a composite',
      () async {
        const registry = PassFailDetectorRegistry();
        final status = await registry.classifyAsync(
          config: CompositePassFailConfig(
            anyOf: const [RegexPassFailConfig(failPattern: r'(a+)+$')],
          ),
          stdout: bomb,
          stderr: '',
          exitCode: 0,
          runtime: Duration.zero,
          regexDeadline: const Duration(milliseconds: 500),
        );
        // No child produced a conclusive signal ⇒ unknown.
        expect(status, TestStatus.unknown);
      },
      timeout: const Timeout(Duration(seconds: 5)),
    );

    test('classifyAsync still classifies a normal regex correctly', () async {
      const registry = PassFailDetectorRegistry();
      final status = await registry.classifyAsync(
        config: const RegexPassFailConfig(failPattern: 'UVM_ERROR'),
        stdout: 'sim start\nUVM_ERROR : 2 errors',
        stderr: '',
        exitCode: 0,
        runtime: Duration.zero,
      );
      expect(status, TestStatus.fail);
    });
  });

  group('RegexDetector — input scan bound', () {
    TestStatus detect(RegexDetector detector, String stdout) => detector.detect(
      stdout: stdout,
      stderr: '',
      exitCode: 0,
      runtime: Duration.zero,
      config: const RegexPassFailConfig(failPattern: 'FAIL_TOKEN'),
    );

    test(
      'a fail token beyond the scan bound is not matched — removing the '
      'bound (the mutation) makes this match and flips the verdict',
      () {
        // FAIL_TOKEN only appears at the very head, beyond the trailing
        // scan window, so the bounded detector never sees it.
        final log = 'FAIL_TOKEN${'.' * 100000}tail';
        const bounded = RegexDetector(maxScanChars: 1000);
        expect(detect(bounded, log), TestStatus.unknown);

        // Control: an unbounded scan would see it (and classify fail).
        const unbounded = RegexDetector(maxScanChars: 1 << 30);
        expect(detect(unbounded, log), TestStatus.fail);
      },
    );

    test('a fail token within the scan window is still matched', () {
      final log = '${'.' * 100}FAIL_TOKEN at the tail';
      const detector = RegexDetector(maxScanChars: 1000);
      expect(detect(detector, log), TestStatus.fail);
    });
  });
}
