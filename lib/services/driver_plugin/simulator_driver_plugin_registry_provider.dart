// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/interfaces/simulator_driver_plugin_registry.dart';
import 'package:simcrux/domain/models/simulator_driver_plugin_manifest.dart';

/// Open-core extension-point seam for the custom simulator-driver
/// plugin registry.
///
/// Defaults to [NoopSimulatorDriverPluginRegistry] so an open-core
/// build never spawns subprocesses or scans plugin directories. The
/// Pro overlay replaces this provider with the concrete
/// `SubprocessSimulatorDriverPluginRegistry` via `proOverrides`.
///
/// Consumers should NOT call [SimulatorDriverPluginRegistry.shutdownAll]
/// directly from request paths — the app's `bootstrap()` arranges
/// shutdown during app teardown via a `ref.onDispose` hook.
final Provider<SimulatorDriverPluginRegistry>
simulatorDriverPluginRegistryProvider = Provider<SimulatorDriverPluginRegistry>(
  (ref) => const NoopSimulatorDriverPluginRegistry(),
);

/// Async snapshot of every plugin manifest the active registry knows
/// about.
///
/// Settings → Plugins and the plugin events dialog consume this to
/// render the per-plugin cards. Re-fetched after a successful
/// install / uninstall via `ref.invalidate(installedPluginsProvider)`
/// from the install / uninstall actions.
///
/// A scan that fails is not retried. Riverpod retries a failing provider by
/// default, ten times over about forty seconds, and `.future` waits through
/// all of them; a plugin folder that cannot be listed (its permissions, a
/// missing mount) does not fix itself in that time. Retrying left the
/// Settings list on a spinner and a Reload with nothing to say. Reload is
/// the retry, and it is the user's to make.
final FutureProvider<List<SimulatorDriverPluginManifest>>
installedPluginsProvider = FutureProvider<List<SimulatorDriverPluginManifest>>(
  (ref) {
    final registry = ref.watch(simulatorDriverPluginRegistryProvider);
    return registry.listInstalled();
  },
  retry: (_, _) => null,
);

/// Rolling window of the last `kPluginEventsLogCapacity` lifecycle
/// events from the active registry. Subscribed by the plugin events
/// dialog; bounded so memory stays predictable even under flaky
/// plugins that crash repeatedly.
const int kPluginEventsLogCapacity = 100;

/// Bounded buffer of recent [PluginEvent]s. Subscribed by the Pro
/// overlay's plugin events dialog.
final StreamProvider<List<PluginEvent>> pluginEventsLogProvider =
    StreamProvider<List<PluginEvent>>((ref) async* {
      final registry = ref.watch(simulatorDriverPluginRegistryProvider);
      final buffer = <PluginEvent>[];
      yield List<PluginEvent>.unmodifiable(buffer);
      await for (final event in registry.events) {
        buffer.add(event);
        if (buffer.length > kPluginEventsLogCapacity) {
          buffer.removeRange(0, buffer.length - kPluginEventsLogCapacity);
        }
        yield List<PluginEvent>.unmodifiable(buffer);
      }
    });
