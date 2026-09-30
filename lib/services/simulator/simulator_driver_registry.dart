// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/interfaces/simulator_driver_plugin_registry.dart';

/// Maps a [TestSpec.simulatorId] to its [SimulatorDriver].
///
/// Built-ins are `icarus`, `verilator`, `ghdl`, `cocotb` and the two
/// RISC-V drivers; plugins add `xsim`, `questa`, etc. The
/// built-in registry is intentionally minimal — no hot-swapping —
/// because the built-in driver set is fixed at build time.
///
/// The optional [pluginRegistry] hook lets the
/// runner can resolve custom simulator drivers contributed by
/// user-installed plugins. Resolution precedence is documented on
/// [resolveDriverFor]: built-in drivers win on name collision so the
/// SimCrux-provided implementation always takes priority over a
/// plugin claiming the same simulator id.
class SimulatorDriverRegistry {
  /// Creates a [SimulatorDriverRegistry] from a map of
  /// `simulatorId` → [SimulatorDriver].
  ///
  /// Pass [pluginRegistry] to enable async lookup of
  /// plugin-contributed drivers via [resolveDriverFor]. When omitted
  /// the registry resolves built-ins only.
  SimulatorDriverRegistry(
    Map<String, SimulatorDriver> drivers, {
    this.pluginRegistry,
  }) : _drivers = Map<String, SimulatorDriver>.unmodifiable(drivers);

  final Map<String, SimulatorDriver> _drivers;

  /// Optional plugin registry consulted by [resolveDriverFor] when
  /// the requested simulatorId is not satisfied by a built-in driver.
  /// Pass [NoopSimulatorDriverPluginRegistry] (or null) to disable
  /// plugin resolution.
  final SimulatorDriverPluginRegistry? pluginRegistry;

  /// Returns the **built-in** driver registered for [simulatorId], or
  /// null when no built-in driver is registered for that id.
  ///
  /// This intentionally ignores plugin-contributed drivers — callers
  /// that need to consult the full driver universe (built-ins +
  /// plugins) must use [resolveDriverFor].
  SimulatorDriver? driverFor(String simulatorId) => _drivers[simulatorId];

  /// All registered built-in simulator ids.
  Iterable<String> get simulatorIds => _drivers.keys;

  /// All registered built-in drivers.
  Iterable<SimulatorDriver> get drivers => _drivers.values;

  /// Resolves [simulatorId] against the built-in registry first, then
  /// against the optional plugin registry.
  ///
  /// **Precedence rule.** Built-in drivers always win on name
  /// collision. If a plugin claims the same id as a built-in driver
  /// (e.g. a plugin claiming `verilator`), the plugin is silently
  /// shadowed and the built-in is used. This guarantees that
  /// installing a plugin never accidentally changes the behavior of
  /// a built-in simulator. Plugin authors who want to override a
  /// built-in must publish under a different simulatorId (e.g.
  /// `verilator-experimental`) and have users explicitly opt in via
  /// their `TestSpec`.
  ///
  /// Returns `null` when neither the built-in registry nor the
  /// plugin registry recognizes [simulatorId].
  Future<SimulatorDriver?> resolveDriverFor(String simulatorId) async {
    final builtIn = _drivers[simulatorId];
    if (builtIn != null) return builtIn;
    final plugins = pluginRegistry;
    if (plugins == null) return null;
    final manifests = await plugins.listInstalled();
    for (final manifest in manifests) {
      if (!manifest.supportedSimulators.contains(simulatorId)) continue;
      final driver = await plugins.instantiate(manifest.pluginId);
      // Keep looking rather than returning the null. A registry declines to
      // instantiate for reasons that are specific to one plugin — the user
      // switched it off, its executable is missing, its handshake timed out
      // — and none of those are a reason to give up on a second installed
      // plugin that also claims this simulator.
      if (driver != null) return driver;
    }
    return null;
  }
}
