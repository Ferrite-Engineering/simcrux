// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/interfaces/retry_policy.dart';

/// Extension-point seam for the active per-test [RetryPolicy].
///
/// Open-core ships [NoopRetryPolicy] as the default — tests never
/// retry automatically. The Pro overlay overrides this
/// provider in `proOverrides` with a `FlakyRetryPolicy` that consults
/// the active flaky-detection scores and reruns flaky-classified
/// tests up to `FlakinessConfig.autoRetryAttempts` times.
///
/// Consumed by [LocalJobScheduler] inside its per-test execution loop
/// immediately after a non-passing terminal status is recorded —
/// see `lib/services/job_scheduler/local_job_scheduler.dart`.
final Provider<RetryPolicy> retryPolicyProvider = Provider<RetryPolicy>(
  (ref) => const NoopRetryPolicy(),
);
