// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/services/job_scheduler/dump_retention.dart';

/// Active [DumpRetentionPolicy] for per-test working-directory / waveform
/// dump retention.
///
/// Defaults to [DumpRetentionPolicy.defaultPolicy] (keep the 50 most
/// recent failures, 2 GiB ceiling). Tests and the Pro settings surface
/// override this provider to install a custom policy; the scheduler reads
/// it (via `jobSchedulerProvider`) and prunes the run directory after
/// each regression completes, mirroring how `retentionPolicyProvider`
/// caps the SQLite trend store.
final Provider<DumpRetentionPolicy> dumpRetentionPolicyProvider =
    Provider<DumpRetentionPolicy>((_) => DumpRetentionPolicy.defaultPolicy);
