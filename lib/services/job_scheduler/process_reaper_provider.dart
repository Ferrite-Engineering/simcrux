// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/services/job_scheduler/process_reaper.dart';

/// Open-core seam for the active [ProcessReaper].
///
/// Defaults to [defaultProcessReaper] so production builds reap process
/// trees on every desktop platform (POSIX descendant chain / Windows
/// `taskkill /T`). Unit tests override this with a `FakeProcessRunner`
/// (a faithful in-process model of OS tree behaviour); the Pro overlay's
/// plugin path consumes the same provider unchanged so plugin subprocess
/// trees are reaped by the identical escalation policy.
///
/// The interface, the escalation control flow, and the platform reapers
/// live in `process_reaper.dart` with no Flutter dependency so the
/// orchestration corpus generator and soak harness can replay scenarios
/// under a plain `dart run`.
final Provider<ProcessReaper> processReaperProvider = Provider<ProcessReaper>(
  (_) => defaultProcessReaper(),
);
