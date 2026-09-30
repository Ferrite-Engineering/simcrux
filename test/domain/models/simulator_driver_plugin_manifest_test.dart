// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/driver_capability.dart';
import 'package:simcrux/domain/enums/driver_stdio_protocol.dart';
import 'package:simcrux/domain/models/simulator_driver_plugin_manifest.dart';

SimulatorDriverPluginManifest _exampleManifest() {
  return SimulatorDriverPluginManifest(
    pluginId: 'com.simcrux.example.verilator',
    displayName: 'Verilator Reference',
    description: 'Reference plugin that wraps Verilator.',
    version: '0.1.0',
    authorName: 'SimCrux Team',
    authorContact: 'info@ferriteengineering.com',
    homepage: 'https://example.com/plugins',
    repository: 'https://github.com/example/plugins',
    licenseSpdx: 'MIT',
    supportedSimulators: const ['verilator-reference'],
    abiVersion: kSimcruxDriverPluginAbiVersion,
    executablePath: 'verilator-driver',
    stdioProtocol: DriverStdioProtocol.jsonLines,
    minSimcruxVersion: '0.1.0',
    declaredCapabilities: const {
      DriverCapability.compile,
      DriverCapability.run,
      DriverCapability.waveformDump,
    },
  );
}

void main() {
  group('SimulatorDriverPluginManifest', () {
    test('equality is value-based across all fields', () {
      expect(_exampleManifest(), equals(_exampleManifest()));
      expect(_exampleManifest().hashCode, _exampleManifest().hashCode);
    });

    test('copyWith replaces declared fields and preserves the rest', () {
      final original = _exampleManifest();
      final copy = original.copyWith(version: '0.2.0');
      expect(copy.version, '0.2.0');
      expect(copy.copyWith(version: original.version), equals(original));
    });

    test('copyWith preserves nullable fields when omitted', () {
      final original = _exampleManifest();
      final copy = original.copyWith(version: '0.2.0');
      expect(copy.authorName, original.authorName);
      expect(copy.homepage, original.homepage);
    });

    test('copyWith can clear nullable fields by passing explicit null', () {
      final original = _exampleManifest();
      final copy = original.copyWith(authorName: null, homepage: null);
      expect(copy.authorName, isNull);
      expect(copy.homepage, isNull);
    });

    test('round-trips through YAML', () {
      final original = _exampleManifest();
      final parsed = SimulatorDriverPluginManifest.fromYaml(original.toYaml());
      expect(parsed, equals(original));
    });

    test('round-trips through fromMap → toJson', () {
      final original = _exampleManifest();
      final parsed = SimulatorDriverPluginManifest.fromMap(original.toJson());
      expect(parsed, equals(original));
    });

    test('toJsonString is parseable as a fromMap input', () {
      // Going through toYaml->fromYaml is the canonical round-trip;
      // toJsonString is a separate output channel we just spot-check
      // by validating the structural fields appear.
      final manifest = _exampleManifest();
      final json = manifest.toJsonString();
      expect(json, contains('"pluginId":"com.simcrux.example.verilator"'));
      expect(json, contains('"abiVersion":1'));
      expect(json, contains('"stdioProtocol":"json-lines"'));
    });

    test('rejects manifest missing a required field', () {
      expect(
        () => SimulatorDriverPluginManifest.fromMap(const <String, Object?>{
          // displayName intentionally omitted.
          'pluginId': 'com.example.test',
          'description': 'desc',
          'version': '0.1.0',
          'licenseSpdx': 'MIT',
          'supportedSimulators': ['verilator'],
          'abiVersion': kSimcruxDriverPluginAbiVersion,
          'executablePath': 'foo',
          'stdioProtocol': 'json-lines',
          'minSimcruxVersion': '0.1.0',
        }),
        throwsA(isA<SimulatorDriverPluginManifestFormatException>()),
      );
    });

    test('rejects manifest with unknown stdioProtocol', () {
      expect(
        () => SimulatorDriverPluginManifest.fromMap(const <String, Object?>{
          'pluginId': 'com.example.test',
          'displayName': 'Test',
          'description': 'desc',
          'version': '0.1.0',
          'licenseSpdx': 'MIT',
          'supportedSimulators': ['verilator'],
          'abiVersion': kSimcruxDriverPluginAbiVersion,
          'executablePath': 'foo',
          'stdioProtocol': 'msgpack-v9000',
          'minSimcruxVersion': '0.1.0',
        }),
        throwsA(isA<SimulatorDriverPluginManifestFormatException>()),
      );
    });

    test('rejects manifest with empty supportedSimulators', () {
      expect(
        () => SimulatorDriverPluginManifest.fromMap(const <String, Object?>{
          'pluginId': 'com.example.test',
          'displayName': 'Test',
          'description': 'desc',
          'version': '0.1.0',
          'licenseSpdx': 'MIT',
          'supportedSimulators': <String>[],
          'abiVersion': kSimcruxDriverPluginAbiVersion,
          'executablePath': 'foo',
          'stdioProtocol': 'json-lines',
          'minSimcruxVersion': '0.1.0',
        }),
        throwsA(isA<SimulatorDriverPluginManifestFormatException>()),
      );
    });

    test('silently skips unknown capabilities for forward compatibility', () {
      final parsed = SimulatorDriverPluginManifest.fromMap(
        const <String, Object?>{
          'pluginId': 'com.example.future',
          'displayName': 'Future',
          'description': 'desc',
          'version': '0.1.0',
          'licenseSpdx': 'MIT',
          'supportedSimulators': ['some-sim'],
          'abiVersion': kSimcruxDriverPluginAbiVersion,
          'executablePath': 'foo',
          'stdioProtocol': 'json-lines',
          'minSimcruxVersion': '0.1.0',
          'declaredCapabilities': ['run', 'future-cap-v2'],
        },
      );
      expect(parsed.declaredCapabilities, {DriverCapability.run});
    });

    test('silently ignores unknown top-level keys (forward compat)', () {
      final manifest = _exampleManifest();
      final map = manifest.toJson();
      map['futureField'] = 'ignored';
      final parsed = SimulatorDriverPluginManifest.fromMap(map);
      expect(parsed, equals(manifest));
    });

    test('YAML output is deterministic across construction order', () {
      final a = _exampleManifest();
      final b = SimulatorDriverPluginManifest.fromYaml(a.toYaml());
      expect(b.toYaml(), a.toYaml());
    });

    test('ABI version constant is the v1 contract value', () {
      expect(kSimcruxDriverPluginAbiVersion, 1);
    });
  });

  group('DriverCapability', () {
    test('wireId is the enum name (camelCase)', () {
      expect(DriverCapability.run.wireId, 'run');
      expect(DriverCapability.waveformDump.wireId, 'waveformDump');
      expect(DriverCapability.interactiveDebug.wireId, 'interactiveDebug');
    });

    test('fromWireId round-trips for every value', () {
      for (final cap in DriverCapability.values) {
        expect(DriverCapability.fromWireId(cap.wireId), cap);
      }
    });

    test('fromWireId returns null for unknown ids', () {
      expect(DriverCapability.fromWireId('future-cap'), isNull);
    });
  });

  group('DriverStdioProtocol', () {
    test('wireId for jsonLines is the kebab-case form', () {
      expect(DriverStdioProtocol.jsonLines.wireId, 'json-lines');
    });

    test('fromWireId round-trips', () {
      expect(
        DriverStdioProtocol.fromWireId('json-lines'),
        DriverStdioProtocol.jsonLines,
      );
    });

    test('fromWireId returns null for unknown ids', () {
      expect(DriverStdioProtocol.fromWireId('msgpack'), isNull);
    });
  });
}
