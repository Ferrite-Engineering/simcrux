// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';

/// Detected versions of the built-in simulator backends, keyed by
/// `SimulatorDriver.id` (`icarus`, `verilator`, `ghdl`, `cocotb`).
///
/// A simulator that is not installed, not executable, or whose version probe
/// fails is simply absent from the map — `SimulatorDriver.detectVersion` is
/// contractually non-throwing and returns `null` in those cases.
///
/// **Why this exists.** "Which simulator, at which version" is the single most
/// load-bearing fact in a SimCrux bug report: nearly every orchestration
/// defect is a version-specific output-format or flag difference. The report's
/// Session State category folds this map in, which is why it lives at the
/// feature layer (it composes settings + the driver registry) rather than
/// under `services/`.
///
/// **Cost.** Resolving this provider spawns one short-lived `--version`
/// subprocess per built-in driver. It is therefore *lazy*: nothing reads it
/// until the beta issue reporter opens (the reporter's dialog watches the
/// session context, so the tiles and the markdown preview refresh in place
/// when the probe resolves). It is never warmed at startup — an app launch
/// must not pay four process spawns for a report the user may never file.
///
/// Honors the per-simulator binary overrides from Settings → Simulators, so a
/// user pointing SimCrux at a non-`$PATH` Verilator gets *that* build's
/// version in the report rather than the system one's.
final FutureProvider<Map<String, String>> simulatorVersionsProvider =
    FutureProvider<Map<String, String>>((ref) async {
      final registry = ref.watch(simulatorDriverRegistryProvider);
      final overrides =
          ref.watch(appSettingsProvider).value?.simulatorBinaryOverrides ??
          const <String, String>{};

      final detected = <String, String>{};
      for (final driver in registry.drivers) {
        final customPath = overrides[driver.id];
        final hasOverride = customPath != null && customPath.isNotEmpty;
        final version = await driver.detectVersion(
          SimulatorBinaryConfig(
            simulatorId: driver.id,
            // `custom` is the only source that consults `customPath`;
            // `system` resolves the bare binary name against the host
            // `$PATH`, which is the right probe when the user has set no
            // override. (This said `bundled` while that was the model's
            // default — behaviorally identical, but it made the probe
            // describe a resolution path that does not exist.)
            source: hasOverride
                ? SimulatorBinarySource.custom
                : SimulatorBinarySource.system,
            customPath: hasOverride ? customPath : null,
          ),
        );
        if (version != null && version.trim().isNotEmpty) {
          detected[driver.id] = version.trim();
        }
      }
      return Map<String, String>.unmodifiable(detected);
    }, name: 'simulatorVersionsProvider');
