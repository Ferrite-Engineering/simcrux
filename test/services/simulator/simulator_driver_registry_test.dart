// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/driver_capability.dart';
import 'package:simcrux/domain/enums/driver_stdio_protocol.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/interfaces/simulator_driver_plugin_registry.dart';
import 'package:simcrux/domain/models/simulator_driver_plugin_manifest.dart';
import 'package:simcrux/services/simulator/cocotb_driver.dart';
import 'package:simcrux/services/simulator/ghdl_driver.dart';
import 'package:simcrux/services/simulator/icarus_driver.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';
import 'package:simcrux/services/simulator/verilator_driver.dart';

class _StubPluginDriver implements SimulatorDriverPluginInterface {
  _StubPluginDriver(this.manifest);

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

class _StubPluginRegistry implements SimulatorDriverPluginRegistry {
  _StubPluginRegistry(this.manifests, {this.refuse = const <String>{}});

  final List<SimulatorDriverPluginManifest> manifests;

  /// Plugin ids this registry declines to instantiate — the shape of a
  /// user-disabled plugin, a missing executable, or a handshake timeout.
  final Set<String> refuse;

  @override
  Future<List<SimulatorDriverPluginManifest>> listInstalled() async =>
      manifests;

  @override
  Future<SimulatorDriverPluginInterface?> instantiate(String pluginId) async {
    if (refuse.contains(pluginId)) return null;
    for (final manifest in manifests) {
      if (manifest.pluginId == pluginId) {
        return _StubPluginDriver(manifest);
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
    description: 'stub',
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
  group('SimulatorDriverRegistry', () {
    test('returns the registered driver for a simulatorId', () {
      final icarus = IcarusDriver();
      final registry = SimulatorDriverRegistry({'icarus': icarus});
      expect(registry.driverFor('icarus'), same(icarus));
    });

    test('returns null for an unregistered simulatorId', () {
      final registry = SimulatorDriverRegistry({'icarus': IcarusDriver()});
      expect(registry.driverFor('verilator'), isNull);
    });

    test('exposes registered ids and drivers', () {
      final icarus = IcarusDriver();
      final registry = SimulatorDriverRegistry({'icarus': icarus});
      expect(registry.simulatorIds, ['icarus']);
      expect(registry.drivers.single, same(icarus));
    });

    test(
      'holds the Icarus, Verilator, GHDL and Cocotb drivers side-by-side',
      () {
        final icarus = IcarusDriver();
        final verilator = VerilatorDriver();
        final ghdl = GhdlDriver();
        final cocotb = CocotbDriver();
        final registry = SimulatorDriverRegistry({
          'icarus': icarus,
          'verilator': verilator,
          'ghdl': ghdl,
          'cocotb': cocotb,
        });
        expect(registry.driverFor('icarus'), same(icarus));
        expect(registry.driverFor('verilator'), same(verilator));
        expect(registry.driverFor('ghdl'), same(ghdl));
        expect(registry.driverFor('cocotb'), same(cocotb));
        expect(
          registry.simulatorIds.toSet(),
          {'icarus', 'verilator', 'ghdl', 'cocotb'},
        );
      },
    );
  });

  group('SimulatorDriverRegistry.resolveDriverFor', () {
    test('resolves a built-in when no plugin registry is wired', () async {
      final icarus = IcarusDriver();
      final registry = SimulatorDriverRegistry({'icarus': icarus});
      expect(await registry.resolveDriverFor('icarus'), same(icarus));
    });

    test('returns null when neither built-in nor plugin matches', () async {
      final registry = SimulatorDriverRegistry(
        {'icarus': IcarusDriver()},
        pluginRegistry: const NoopSimulatorDriverPluginRegistry(),
      );
      expect(await registry.resolveDriverFor('unknown-sim'), isNull);
    });

    test('falls back to a plugin when no built-in matches', () async {
      final manifest = _manifest(
        pluginId: 'com.example.xsim',
        supportedSimulators: ['xsim'],
      );
      final registry = SimulatorDriverRegistry(
        {'icarus': IcarusDriver()},
        pluginRegistry: _StubPluginRegistry([manifest]),
      );
      final resolved = await registry.resolveDriverFor('xsim');
      expect(resolved, isNotNull);
      expect(resolved, isA<SimulatorDriverPluginInterface>());
      expect(resolved!.id, 'xsim');
    });

    test(
      'built-in wins on name collision (built-in driver returned, plugin shadowed)',
      () async {
        final icarus = IcarusDriver();
        final collidingPlugin = _manifest(
          pluginId: 'com.example.icarus-clone',
          supportedSimulators: ['icarus'],
        );
        final registry = SimulatorDriverRegistry(
          {'icarus': icarus},
          pluginRegistry: _StubPluginRegistry([collidingPlugin]),
        );
        final resolved = await registry.resolveDriverFor('icarus');
        expect(resolved, same(icarus));
        expect(resolved, isNot(isA<SimulatorDriverPluginInterface>()));
      },
    );

    test(
      'plugin registry list order chooses the first matching plugin on a name',
      () async {
        final first = _manifest(
          pluginId: 'com.example.first',
          supportedSimulators: ['shared'],
        );
        final second = _manifest(
          pluginId: 'com.example.second',
          supportedSimulators: ['shared'],
        );
        final registry = SimulatorDriverRegistry(
          {},
          pluginRegistry: _StubPluginRegistry([first, second]),
        );
        final resolved = await registry.resolveDriverFor('shared');
        expect(resolved, isA<SimulatorDriverPluginInterface>());
        expect(
          (resolved! as SimulatorDriverPluginInterface).manifest.pluginId,
          'com.example.first',
        );
      },
    );
  });

  group('resolveDriverFor skips plugins that decline to instantiate', () {
    test('a refused plugin does not shadow a later one that also supports '
        'the simulator — the loop used to return the first null', () async {
      final plugins = _StubPluginRegistry(
        [
          _manifest(pluginId: 'disabled.one', supportedSimulators: ['acme']),
          _manifest(pluginId: 'working.two', supportedSimulators: ['acme']),
        ],
        refuse: {'disabled.one'},
      );
      final registry = SimulatorDriverRegistry(
        const <String, SimulatorDriver>{},
        pluginRegistry: plugins,
      );

      final driver = await registry.resolveDriverFor('acme');

      expect(driver, isNotNull);
      expect(
        (driver! as SimulatorDriverPluginInterface).manifest.pluginId,
        'working.two',
      );
    });

    test('returns null when every candidate declines', () async {
      final plugins = _StubPluginRegistry(
        [
          _manifest(pluginId: 'only.one', supportedSimulators: ['acme']),
        ],
        refuse: {'only.one'},
      );
      final registry = SimulatorDriverRegistry(
        const <String, SimulatorDriver>{},
        pluginRegistry: plugins,
      );

      expect(await registry.resolveDriverFor('acme'), isNull);
    });
  });
}
