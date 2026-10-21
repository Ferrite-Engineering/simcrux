// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/cli/simcrux_cli.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';
import 'package:simcrux/services/simulator/riscv_formal_driver.dart';
import 'package:simcrux/services/simulator/sby_driver.dart';

// A driver registered nowhere compiles, analyzes and keeps its own tests
// green. These pin the two places the app resolves `simulator: sby` (the
// desktop scheduler's registry and the headless CLI's), and that the RISC-V
// track still resolves to its own specialisation of the same driver.

void main() {
  test('the desktop registry resolves `sby` to SbyDriver', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final registry = container.read(simulatorDriverRegistryProvider);
    final driver = registry.driverFor(SbyDriver.kId);
    expect(driver, isA<SbyDriver>());
    expect(driver, isNot(isA<RiscvFormalDriver>()));
    expect(registry.driverFor(RiscvFormalDriver.kId), isA<RiscvFormalDriver>());
    expect(registry.driverFor(RiscvFormalDriver.kId), isA<SbyDriver>());
  });

  test('the headless CLI registry resolves `sby` to SbyDriver', () {
    final registry = SimcruxCli.defaultDriverRegistry();
    expect(registry.driverFor(SbyDriver.kId), isA<SbyDriver>());
    expect(registry.driverFor(RiscvFormalDriver.kId), isA<RiscvFormalDriver>());
  });

  test('both registries list the same driver ids', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(
      container.read(simulatorDriverRegistryProvider).simulatorIds.toSet(),
      SimcruxCli.defaultDriverRegistry().simulatorIds.toSet(),
    );
  });
}
