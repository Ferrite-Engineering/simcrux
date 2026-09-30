// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/simulator_driver_plugin_manifest.dart';

/// Open-core extension-point interface for custom simulator-driver
/// plugins.
///
/// The interface stays narrow on purpose: enumerate installed
/// manifests, instantiate a driver subprocess on demand, and surface
/// lifecycle events. The concrete subprocess loader implementation
/// (`SubprocessSimulatorDriverPluginRegistry`) lives in the
/// Pro overlay because the loader is a Pro-tier feature
/// requiring license-gated activation; open-core ships
/// [NoopSimulatorDriverPluginRegistry] so the runner and Settings UI
/// have a well-defined no-op surface to consume.
///
/// **Process isolation.** Implementations MUST run each plugin as a
/// separate OS subprocess. `dart:ffi`-style in-process loading is
/// forbidden by the open-core/Pro contract because it conflates GPL
/// (or proprietary) plugin code with the host process and removes the
/// crash-isolation guarantee.
abstract class SimulatorDriverPluginRegistry {
  /// Enumerates the manifests currently installed in the configured
  /// plugin directory. Implementations cache results internally; the
  /// host re-queries after a successful install / uninstall via the
  /// `reloadPlugins` action.
  Future<List<SimulatorDriverPluginManifest>> listInstalled();

  /// Spawns the subprocess for [pluginId], performs the initialization
  /// handshake, and returns a ready-to-use driver. Returns `null` if
  /// the pluginId is not known to this registry; throws on handshake
  /// failure (ABI mismatch, timeout, non-conformant response).
  ///
  /// Implementations cache active instances per pluginId — repeated
  /// calls return the same driver until [shutdownAll] or a failure
  /// tears it down.
  Future<SimulatorDriverPluginInterface?> instantiate(String pluginId);

  /// Lifecycle events emitted by the registry (plugin install /
  /// remove, subprocess crash, heartbeat timeout). Consumed by the
  /// Settings → Plugins panel and by the per-pane plugin events
  /// dialog.
  Stream<PluginEvent> get events;

  /// Gracefully terminates every active plugin subprocess. Called on
  /// app shutdown. Implementations follow the canonical escalation
  /// policy: send `shutdown` request → wait up to 5 seconds →
  /// `SIGTERM` → wait 2 seconds → `SIGKILL`.
  Future<void> shutdownAll();
}

/// Default open-core implementation: enumerates nothing, instantiates
/// nothing, emits no events. The runner falls back to its built-in
/// driver set when this implementation is active.
///
/// Tests use this as the baseline when the Pro overlay is not loaded.
class NoopSimulatorDriverPluginRegistry
    implements SimulatorDriverPluginRegistry {
  /// Creates a [NoopSimulatorDriverPluginRegistry].
  const NoopSimulatorDriverPluginRegistry();

  @override
  Future<List<SimulatorDriverPluginManifest>> listInstalled() async =>
      const <SimulatorDriverPluginManifest>[];

  @override
  Future<SimulatorDriverPluginInterface?> instantiate(String pluginId) async =>
      null;

  @override
  Stream<PluginEvent> get events => const Stream<PluginEvent>.empty();

  @override
  Future<void> shutdownAll() async {
    // Nothing to shut down.
  }
}

/// A [SimulatorDriver] that is backed by a plugin subprocess.
///
/// Mirrors the open-core [SimulatorDriver] interface (so the runner
/// can consume it through the same surface) and adds [manifest] +
/// [shutdown] for plugin-lifecycle introspection. The Pro overlay's
/// `SubprocessSimulatorDriverPluginRegistry.instantiate` returns
/// instances of this interface.
abstract class SimulatorDriverPluginInterface implements SimulatorDriver {
  /// The manifest this driver was instantiated from.
  SimulatorDriverPluginManifest get manifest;

  /// Gracefully shuts down the backing subprocess. Idempotent —
  /// repeated calls are no-ops once the subprocess has exited.
  Future<void> shutdown();
}

/// Lifecycle event emitted by a [SimulatorDriverPluginRegistry].
///
/// Surfaced in the Settings → Plugins panel and in the per-pane
/// plugin events log dialog. Sealed-style hierarchy with four
/// variants — extend by adding a new subclass when a future event
/// kind is needed (the events stream is forward-compatible).
@immutable
sealed class PluginEvent {
  /// Const default constructor for sealed subclasses.
  const PluginEvent({required this.timestamp});

  /// When the event was observed (UTC).
  final DateTime timestamp;

  /// Plugin id this event applies to. `null` for events not bound to
  /// a specific plugin (e.g. registry-level scan failures).
  String? get pluginId;
}

/// Emitted after a successful install / first-time-scan discovery.
@immutable
class PluginInstalled extends PluginEvent {
  /// Creates a [PluginInstalled].
  const PluginInstalled({
    required super.timestamp,
    required this.pluginId,
    required this.displayName,
  });

  @override
  final String pluginId;

  /// User-facing display name from the manifest.
  final String displayName;
}

/// Emitted after a plugin is uninstalled / its install directory
/// disappears.
@immutable
class PluginRemoved extends PluginEvent {
  /// Creates a [PluginRemoved].
  const PluginRemoved({
    required super.timestamp,
    required this.pluginId,
  });

  @override
  final String pluginId;
}

/// Emitted when a plugin subprocess exits unexpectedly mid-operation
/// (crash, kill, OOM). The host fails the in-flight request, marks
/// the plugin as errored in the Settings UI, and surfaces the crash
/// in the per-pane plugin events dialog.
@immutable
class PluginCrashed extends PluginEvent {
  /// Creates a [PluginCrashed].
  const PluginCrashed({
    required super.timestamp,
    required this.pluginId,
    required this.exitCode,
    this.message,
  });

  @override
  final String pluginId;

  /// Subprocess exit code, or `null` if unknown.
  final int? exitCode;

  /// Optional reason captured by the host (last stderr line,
  /// protocol error, etc.).
  final String? message;
}

/// Emitted when a plugin fails to respond within the configured
/// heartbeat timeout (default 60 s for compile, 600 s for run).
@immutable
class PluginUnresponsive extends PluginEvent {
  /// Creates a [PluginUnresponsive].
  const PluginUnresponsive({
    required super.timestamp,
    required this.pluginId,
    required this.timeoutSeconds,
    this.operation,
  });

  @override
  final String pluginId;

  /// The threshold (seconds) that elapsed without a response.
  final int timeoutSeconds;

  /// Optional operation name (`initialize`, `compile`, `run`) that
  /// hit the timeout. `null` if not bound to a specific operation.
  final String? operation;
}
