// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/enums/riscv_host_platform.dart';
import 'package:simcrux/domain/models/riscv_config.dart';
import 'package:simcrux/domain/models/riscv_toolchain_report.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';
import 'package:simcrux/services/simulator/riscv_arch_driver.dart';

/// The host platform the RISC-V toolchain guidance is phrased for.
///
/// A provider rather than a direct `Platform` read so a widget test can
/// render all three platforms' guidance from one CI runner — which is the
/// only way the Windows copy (the one with the WSL2 answer, and the one
/// least likely to be exercised by hand) gets any coverage at all.
final Provider<RiscvHostPlatform> riscvHostPlatformProvider =
    Provider<RiscvHostPlatform>(
      (ref) => RiscvHostPlatform.fromFlags(
        isMacOS: Platform.isMacOS,
        isWindows: Platform.isWindows,
      ),
      name: 'riscvHostPlatformProvider',
    );

/// Per-component state of the RISC-V toolchain, for the diagnostics panel.
///
/// **Lazy, like `simulatorVersionsProvider`.** Resolving it spawns four
/// short-lived probe subprocesses, so nothing reads it until a panel that
/// shows it is opened; an app launch pays nothing. Non-throwing end to end —
/// the underlying probe swallows `ProcessException` and a non-zero exit
/// alike, and reports "not found" instead.
///
/// Probed against `$PATH` defaults: the diagnostics panel is process-wide
/// and has no project `riscv:` block to consult. A run's own config is what
/// the driver uses at execution time.
final FutureProvider<RiscvToolchainReport> riscvToolchainReportProvider =
    FutureProvider<RiscvToolchainReport>((ref) async {
      final registry = ref.watch(simulatorDriverRegistryProvider);
      final driver = registry.driverFor(RiscvArchDriver.kId);
      if (driver is! RiscvArchDriver) {
        return RiscvToolchainReport(components: const <RiscvComponentReport>[]);
      }
      return driver.probeFor().probe(const RiscvConfig());
    }, name: 'riscvToolchainReportProvider');
