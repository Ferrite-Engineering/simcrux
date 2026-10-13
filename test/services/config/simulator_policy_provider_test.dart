// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/simulator_policy.dart';
import 'package:simcrux/features/config/providers/config_loader_provider.dart';
import 'package:simcrux/services/config/simulator_policy_provider.dart';

void main() {
  test('open core resolves no simulator policy', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(simulatorPolicyProvider), SimulatorPolicy.none);
  });

  test('the in-app loader carries an overriding policy', () {
    const policy = SimulatorPolicy(
      fallbackSimulatorId: 'icarus',
      allowedSimulatorIds: {'icarus'},
    );
    final container = ProviderContainer(
      overrides: [simulatorPolicyProvider.overrideWithValue(policy)],
    );
    addTearDown(container.dispose);
    expect(container.read(configLoaderProvider).simulatorPolicy, policy);
  });
}
