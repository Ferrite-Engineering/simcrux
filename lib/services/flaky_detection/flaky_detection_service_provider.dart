// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/interfaces/flaky_detection_service.dart';
import 'package:simcrux/services/flaky_detection/noop_flaky_detection_service.dart';

/// Extension-point seam for the Pro flaky-test detection service.
///
/// Open-core registers [NoopFlakyDetectionService] as the default —
/// every query returns null / empty. The Pro overlay overrides this
/// provider in `proOverrides` with a `FlakyDetectionServiceImpl` that
/// reads from the trend store.
///
/// Mirrors WaveCrux's `debugAdvisorServiceProvider` pattern:
/// open-core ships the seam plus the no-op default, the Pro overlay
/// supplies the engine that does real work.
final Provider<FlakyDetectionService> flakyDetectionServiceProvider =
    Provider<FlakyDetectionService>(
      (ref) => const NoopFlakyDetectionService(),
    );
