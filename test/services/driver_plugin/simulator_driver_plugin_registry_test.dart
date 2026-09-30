// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/driver_capability.dart';
import 'package:simcrux/domain/enums/driver_stdio_protocol.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/interfaces/simulator_driver_plugin_registry.dart';
import 'package:simcrux/domain/models/simulator_driver_plugin_manifest.dart';
import 'package:simcrux/services/driver_plugin/simulator_driver_plugin_registry_provider.dart';

class _FakePluginDriver implements SimulatorDriverPluginInterface {
  _FakePluginDriver(this.manifest);

  @override
  final SimulatorDriverPluginManifest manifest;

  @override
  String get id => manifest.supportedSimulators.first;

  @override
  String get displayName => manifest.displayName;

  @override
  SimulatorCapabilities get capabilities => SimulatorCapabilities(
    supportedLanguages: const {},
    supportsVcd: false,
    supportsFst: false,
    supportsCocotb: false,
    requiresSeparateCompileStep: false,
    emitsStructuredOutput: false,
  );

  @override
  Future<String?> detectVersion(Object config) async => '0.0.0';

  @override
  Future<CompileResult> compile(CompileRequest request) async =>
      throw UnimplementedError();

  @override
  Stream<TestExecutionEvent> execute(ExecuteRequest request) {
    throw UnimplementedError();
  }

  @override
  void cancel(String testId) {}

  @override
  Future<void> shutdown() async {}
}

/// A registry whose scan always throws [error], as one does for a plugin
/// folder that cannot be listed.
class _FailingRegistry implements SimulatorDriverPluginRegistry {
  _FailingRegistry(this.error);

  final Exception error;
  int calls = 0;

  @override
  Future<List<SimulatorDriverPluginManifest>> listInstalled() async {
    calls++;
    throw error;
  }

  @override
  Future<SimulatorDriverPluginInterface?> instantiate(String pluginId) async =>
      null;

  @override
  Stream<PluginEvent> get events => const Stream<PluginEvent>.empty();

  @override
  Future<void> shutdownAll() async {}
}

class _StubRegistry implements SimulatorDriverPluginRegistry {
  _StubRegistry({
    this.manifests = const <SimulatorDriverPluginManifest>[],
  });

  final List<SimulatorDriverPluginManifest> manifests;

  @override
  Future<List<SimulatorDriverPluginManifest>> listInstalled() async =>
      manifests;

  @override
  Future<SimulatorDriverPluginInterface?> instantiate(String pluginId) async {
    for (final manifest in manifests) {
      if (manifest.pluginId == pluginId) {
        return _FakePluginDriver(manifest);
      }
    }
    return null;
  }

  @override
  Stream<PluginEvent> get events => const Stream<PluginEvent>.empty();

  @override
  Future<void> shutdownAll() async {}
}

SimulatorDriverPluginManifest _manifest({
  required String pluginId,
  required List<String> supportedSimulators,
}) {
  return SimulatorDriverPluginManifest(
    pluginId: pluginId,
    displayName: pluginId,
    description: 'fake',
    version: '0.0.0',
    licenseSpdx: 'MIT',
    supportedSimulators: supportedSimulators,
    abiVersion: kSimcruxDriverPluginAbiVersion,
    executablePath: 'driver',
    stdioProtocol: DriverStdioProtocol.jsonLines,
    minSimcruxVersion: '0.0.0',
    declaredCapabilities: const {DriverCapability.run},
  );
}

void main() {
  group('NoopSimulatorDriverPluginRegistry', () {
    const registry = NoopSimulatorDriverPluginRegistry();

    test('listInstalled returns empty', () async {
      expect(await registry.listInstalled(), isEmpty);
    });

    test('instantiate returns null for any id', () async {
      expect(await registry.instantiate('anything'), isNull);
    });

    test('events stream is empty', () async {
      expect(await registry.events.isEmpty, isTrue);
    });

    test('shutdownAll completes without error', () async {
      await registry.shutdownAll();
    });
  });

  group('simulatorDriverPluginRegistryProvider', () {
    test('default is NoopSimulatorDriverPluginRegistry', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final registry = container.read(simulatorDriverPluginRegistryProvider);
      expect(registry, isA<NoopSimulatorDriverPluginRegistry>());
    });

    test('override replaces the default', () {
      final stub = _StubRegistry();
      final container = ProviderContainer(
        overrides: [
          simulatorDriverPluginRegistryProvider.overrideWithValue(stub),
        ],
      );
      addTearDown(container.dispose);
      expect(
        container.read(simulatorDriverPluginRegistryProvider),
        same(stub),
      );
    });
  });

  group('installedPluginsProvider', () {
    test('default surface is empty', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final result = await container.read(installedPluginsProvider.future);
      expect(result, isEmpty);
    });

    test('reads from the active registry', () async {
      final stub = _StubRegistry(
        manifests: [
          _manifest(
            pluginId: 'com.example.alpha',
            supportedSimulators: ['alpha-sim'],
          ),
          _manifest(
            pluginId: 'com.example.beta',
            supportedSimulators: ['beta-sim'],
          ),
        ],
      );
      final container = ProviderContainer(
        overrides: [
          simulatorDriverPluginRegistryProvider.overrideWithValue(stub),
        ],
      );
      addTearDown(container.dispose);
      final result = await container.read(installedPluginsProvider.future);
      expect(result.map((m) => m.pluginId), [
        'com.example.alpha',
        'com.example.beta',
      ]);
    });

    test('a scan that fails is reported at once, not retried', () async {
      // Riverpod retries a failing provider by default, and `.future` waits
      // through the retries: about forty seconds for a plugin folder that
      // cannot be listed, which a retry never fixes. Reload had nothing to
      // report in that time and the Settings list sat on a spinner.
      final registry = _FailingRegistry(
        const FileSystemException('Directory listing failed', '/plugins'),
      );
      final container = ProviderContainer(
        overrides: [
          simulatorDriverPluginRegistryProvider.overrideWithValue(registry),
        ],
      );
      addTearDown(container.dispose);
      container.listen(installedPluginsProvider, (_, _) {});

      final scan = container.read(installedPluginsProvider.future);
      var failed = false;
      unawaited(scan.then<void>((_) {}, onError: (Object _) => failed = true));
      await pumpEventQueue();

      expect(failed, isTrue, reason: 'the error reaches whoever is waiting');
      final state = container.read(installedPluginsProvider);
      expect(state, isA<AsyncError<List<SimulatorDriverPluginManifest>>>());
      expect(state.error, isA<FileSystemException>());
      expect(registry.calls, 1);
    });
  });

  group('PluginEvent variants', () {
    test('PluginInstalled carries displayName + plugin id', () {
      final now = DateTime.utc(2026, 5, 25);
      const id = 'com.example.test';
      const name = 'Example';
      final event = PluginInstalled(
        timestamp: now,
        pluginId: id,
        displayName: name,
      );
      expect(event.pluginId, id);
      expect(event.displayName, name);
      expect(event.timestamp, now);
    });

    test('PluginCrashed carries optional exit code + message', () {
      final event = PluginCrashed(
        timestamp: DateTime.utc(2026, 5, 25),
        pluginId: 'com.example.test',
        exitCode: 134,
        message: 'segfault during initialization',
      );
      expect(event.exitCode, 134);
      expect(event.message, 'segfault during initialization');
    });

    test('PluginUnresponsive carries threshold + operation', () {
      final event = PluginUnresponsive(
        timestamp: DateTime.utc(2026, 5, 25),
        pluginId: 'com.example.test',
        timeoutSeconds: 60,
        operation: 'compile',
      );
      expect(event.timeoutSeconds, 60);
      expect(event.operation, 'compile');
    });
  });
}
