// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/models/simulator_policy.dart';

/// The organization's simulator policy every project load applies: the
/// fallback simulator and the allow-list.
///
/// A seam. Open core resolves [SimulatorPolicy.none] and reads no policy key
/// here; an edition that honours organization policy overrides this
/// provider. Both loaders read it: the in-app `configLoaderProvider` and the
/// desktop `--ci` branch of `bootstrap()`, so a test the app refuses is a
/// test a pipeline refuses too.
///
/// The standalone headless `simcrux` binary has no provider container and
/// applies no organization simulator policy.
final Provider<SimulatorPolicy> simulatorPolicyProvider =
    Provider<SimulatorPolicy>(
      (ref) => SimulatorPolicy.none,
      name: 'simulatorPolicyProvider',
    );
