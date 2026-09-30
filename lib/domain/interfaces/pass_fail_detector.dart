// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';

/// Classify a completed test run into a final [TestStatus].
///
/// Pluggable so users can configure detection strategy per test or
/// per suite via `PassFailConfig`. Implementations include
/// `ExitCodeDetector`, `StringMatchDetector`, `RegexDetector`,
/// `UvmReportDetector` and `CocotbXmlDetector`, with composite
/// (`all_of` / `any_of`) dispatch inlined in `PassFailDetectorRegistry`.
///
// The architectural intent is a polymorphic interface — multiple
// detector implementations are registered keyed by `PassFailConfig`
// variant. The "convert to top-level function" lint hint does not
// apply because 4+ concrete classes plug in against this
// single interface.
abstract class PassFailDetector {
  /// Classify a single completed run.
  ///
  /// All parameters are required. Implementations should be
  /// pure-functional: same inputs → same output.
  TestStatus detect({
    required String stdout,
    required String stderr,
    required int? exitCode,
    required Duration runtime,
    required PassFailConfig config,
  });
}
