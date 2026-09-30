// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/domain/enums/driver_capability.dart';
import 'package:simcrux/domain/enums/driver_stdio_protocol.dart';
import 'package:yaml/yaml.dart';

/// Current ABI version published by this build of SimCrux.
///
/// A plugin manifest must declare an `abiVersion` equal to this
/// constant for the loader to accept it; older or newer plugins are
/// rejected with a logged diagnostic so users see why a plugin
/// failed to load. Major-version bumps signal a breaking change to
/// the wire protocol or manifest schema; the deprecation policy is
/// documented in `include/simcrux_driver_plugin_abi.md`.
const int kSimcruxDriverPluginAbiVersion = 1;

/// A custom simulator driver plugin's `manifest.yaml`, parsed into a
/// strongly-typed model.
///
/// The manifest is the single source of truth for a plugin's
/// identity, lifecycle contract, and feature set. SimCrux scans the
/// configured plugin directory at startup, parses each
/// `manifest.yaml`, validates the ABI version, and registers the
/// plugin into the active [SimulatorDriverPluginRegistry].
///
/// **Wire format.** YAML is the on-disk format because plugin authors
/// typically hand-write the manifest. JSON round-tripping is
/// available via [toJsonString] for cross-product tooling that prefers
/// JSON; both formats accept the same field set.
///
/// **Forward compatibility.** Unknown top-level keys are silently
/// ignored. Unknown values inside an enum-typed field (e.g. an
/// unrecognized [DriverCapability] wireId) are silently skipped.
/// Newer plugins authored against a future ABI revision will load on
/// older SimCrux builds as long as their declared `abiVersion`
/// matches; otherwise the loader rejects them up-front with a
/// diagnostic.
///
/// Part of the driver plugin SDK (`include/simcrux_driver_plugin_abi.md`).
@immutable
class SimulatorDriverPluginManifest {
  /// Creates a [SimulatorDriverPluginManifest].
  SimulatorDriverPluginManifest({
    required this.pluginId,
    required this.displayName,
    required this.description,
    required this.version,
    required this.licenseSpdx,
    required this.abiVersion,
    required this.executablePath,
    required this.stdioProtocol,
    required this.minSimcruxVersion,
    required List<String> supportedSimulators,
    required Set<DriverCapability> declaredCapabilities,
    this.authorName,
    this.authorContact,
    this.homepage,
    this.repository,
  }) : supportedSimulators = List<String>.unmodifiable(supportedSimulators),
       declaredCapabilities = Set<DriverCapability>.unmodifiable(
         declaredCapabilities,
       );

  /// Decodes a [SimulatorDriverPluginManifest] from a parsed JSON /
  /// YAML map. Throws [SimulatorDriverPluginManifestFormatException]
  /// on malformed input (missing required fields, wrong types,
  /// unrecognized protocol).
  factory SimulatorDriverPluginManifest.fromMap(Map<dynamic, dynamic> raw) {
    String requireString(String key) {
      final value = raw[key];
      if (value is! String || value.isEmpty) {
        throw SimulatorDriverPluginManifestFormatException(
          'manifest field `$key` must be a non-empty string',
        );
      }
      return value;
    }

    int requireInt(String key) {
      final value = raw[key];
      if (value is! int) {
        throw SimulatorDriverPluginManifestFormatException(
          'manifest field `$key` must be an integer',
        );
      }
      return value;
    }

    String? optionalString(String key) {
      final value = raw[key];
      if (value == null) return null;
      if (value is! String) {
        throw SimulatorDriverPluginManifestFormatException(
          'manifest field `$key` must be a string when present',
        );
      }
      return value.isEmpty ? null : value;
    }

    final pluginId = requireString('pluginId');
    final stdioWireId = requireString('stdioProtocol');
    final protocol = DriverStdioProtocol.fromWireId(stdioWireId);
    if (protocol == null) {
      throw SimulatorDriverPluginManifestFormatException(
        'manifest field `stdioProtocol` must be one of '
        '${DriverStdioProtocol.values.map((p) => p.wireId).join(', ')}; '
        'got `$stdioWireId` for plugin `$pluginId`',
      );
    }

    final rawSimulators = raw['supportedSimulators'];
    if (rawSimulators is! List || rawSimulators.isEmpty) {
      throw SimulatorDriverPluginManifestFormatException(
        'manifest field `supportedSimulators` must be a non-empty list',
      );
    }
    final supportedSimulators = <String>[];
    for (final entry in rawSimulators) {
      if (entry is! String || entry.isEmpty) {
        throw SimulatorDriverPluginManifestFormatException(
          'each entry in `supportedSimulators` must be a non-empty string',
        );
      }
      supportedSimulators.add(entry);
    }

    final rawCaps = raw['declaredCapabilities'];
    final declaredCapabilities = <DriverCapability>{};
    if (rawCaps != null) {
      if (rawCaps is! List) {
        throw SimulatorDriverPluginManifestFormatException(
          'manifest field `declaredCapabilities` must be a list when present',
        );
      }
      for (final entry in rawCaps) {
        if (entry is! String) {
          continue; // silently skip non-string entries for forward compat
        }
        final cap = DriverCapability.fromWireId(entry);
        if (cap != null) {
          declaredCapabilities.add(cap);
        }
        // Silently skip unknown capabilities — forward-compat with
        // future ABI revisions that add new capability values.
      }
    }

    return SimulatorDriverPluginManifest(
      pluginId: pluginId,
      displayName: requireString('displayName'),
      description: requireString('description'),
      version: requireString('version'),
      authorName: optionalString('authorName'),
      authorContact: optionalString('authorContact'),
      homepage: optionalString('homepage'),
      repository: optionalString('repository'),
      licenseSpdx: requireString('licenseSpdx'),
      supportedSimulators: supportedSimulators,
      abiVersion: requireInt('abiVersion'),
      executablePath: requireString('executablePath'),
      stdioProtocol: protocol,
      minSimcruxVersion: requireString('minSimcruxVersion'),
      declaredCapabilities: declaredCapabilities,
    );
  }

  /// Decodes a [SimulatorDriverPluginManifest] from a YAML document
  /// string. Convenience wrapper around [fromMap].
  factory SimulatorDriverPluginManifest.fromYaml(String source) {
    final doc = loadYaml(source);
    if (doc is! YamlMap) {
      throw SimulatorDriverPluginManifestFormatException(
        'manifest root must be a YAML mapping',
      );
    }
    // YamlMap doesn't expose a typed Map<String, dynamic>, so unwrap
    // into a plain Map for downstream typed access.
    final raw = <dynamic, dynamic>{};
    doc.nodes.forEach((key, value) {
      raw[key is YamlScalar ? key.value : key] = _unwrap(value);
    });
    return SimulatorDriverPluginManifest.fromMap(raw);
  }

  /// Globally unique reverse-DNS identifier (e.g.
  /// `com.simcrux.example.verilator`). The plugin registry uses this
  /// as the lookup key; collisions across installed plugins are
  /// rejected during the directory scan.
  final String pluginId;

  /// User-facing label rendered in the Settings → Plugins panel,
  /// command palette, and plugin events log.
  final String displayName;

  /// Short blurb describing what the plugin does. Surfaced in the
  /// per-plugin card in Settings → Plugins.
  final String description;

  /// Plugin version (semver string). Surfaced alongside [displayName]
  /// in plugin cards and in the plugin events log; used by support
  /// staff to triage bug reports.
  final String version;

  /// Optional plugin author / maintainer name.
  final String? authorName;

  /// Optional contact (email, URL, etc.) for plugin support.
  final String? authorContact;

  /// Optional plugin homepage URL.
  final String? homepage;

  /// Optional plugin source-repository URL.
  final String? repository;

  /// SPDX license identifier (e.g. `MIT`, `GPL-3.0-only`,
  /// `Proprietary`). Surfaced in the per-plugin card so users
  /// understand the licensing terms before invoking the plugin.
  final String licenseSpdx;

  /// Names of the simulator families this driver targets (e.g.
  /// `verilator`, `xcelium`, `questa`). When a `TestSpec` declares
  /// `simulator: <name>`, the runner looks up first in the built-in
  /// driver registry and then in installed plugins whose
  /// [supportedSimulators] include that name.
  final List<String> supportedSimulators;

  /// Protocol-contract version this plugin was authored against. The
  /// loader rejects manifests whose [abiVersion] does not match
  /// [kSimcruxDriverPluginAbiVersion].
  final int abiVersion;

  /// Subprocess executable path, relative to the plugin install
  /// directory (the directory containing this manifest). The loader
  /// spawns this binary with stdin/stdout pipes to drive the wire
  /// protocol.
  final String executablePath;

  /// Wire-protocol format. v1 supports only
  /// [DriverStdioProtocol.jsonLines].
  final DriverStdioProtocol stdioProtocol;

  /// Minimum SimCrux host version this plugin targets (semver
  /// string). Surfaced in the per-plugin card; advisory in v1 — the
  /// loader does not enforce host-version compatibility beyond ABI
  /// version matching.
  final String minSimcruxVersion;

  /// Set of capabilities the plugin advertises. Drives capability
  /// chips in the Settings UI and gates capability-conditional host
  /// behavior (e.g. "Coverage" toggle visible only when the active
  /// driver declares [DriverCapability.coverage]).
  final Set<DriverCapability> declaredCapabilities;

  /// Returns a copy of this manifest with the named fields replaced.
  SimulatorDriverPluginManifest copyWith({
    String? pluginId,
    String? displayName,
    String? description,
    String? version,
    Object? authorName = _sentinel,
    Object? authorContact = _sentinel,
    Object? homepage = _sentinel,
    Object? repository = _sentinel,
    String? licenseSpdx,
    List<String>? supportedSimulators,
    int? abiVersion,
    String? executablePath,
    DriverStdioProtocol? stdioProtocol,
    String? minSimcruxVersion,
    Set<DriverCapability>? declaredCapabilities,
  }) {
    return SimulatorDriverPluginManifest(
      pluginId: pluginId ?? this.pluginId,
      displayName: displayName ?? this.displayName,
      description: description ?? this.description,
      version: version ?? this.version,
      authorName: identical(authorName, _sentinel)
          ? this.authorName
          : authorName as String?,
      authorContact: identical(authorContact, _sentinel)
          ? this.authorContact
          : authorContact as String?,
      homepage: identical(homepage, _sentinel)
          ? this.homepage
          : homepage as String?,
      repository: identical(repository, _sentinel)
          ? this.repository
          : repository as String?,
      licenseSpdx: licenseSpdx ?? this.licenseSpdx,
      supportedSimulators: supportedSimulators ?? this.supportedSimulators,
      abiVersion: abiVersion ?? this.abiVersion,
      executablePath: executablePath ?? this.executablePath,
      stdioProtocol: stdioProtocol ?? this.stdioProtocol,
      minSimcruxVersion: minSimcruxVersion ?? this.minSimcruxVersion,
      declaredCapabilities: declaredCapabilities ?? this.declaredCapabilities,
    );
  }

  /// JSON-natural representation (used by both YAML and JSON
  /// emitters). Capabilities serialize as a sorted list of wire ids
  /// for deterministic output.
  Map<String, dynamic> toJson() {
    final caps = declaredCapabilities.map((c) => c.wireId).toList()..sort();
    final map = <String, dynamic>{
      'pluginId': pluginId,
      'displayName': displayName,
      'description': description,
      'version': version,
      'licenseSpdx': licenseSpdx,
      'supportedSimulators': List<String>.from(supportedSimulators),
      'abiVersion': abiVersion,
      'executablePath': executablePath,
      'stdioProtocol': stdioProtocol.wireId,
      'minSimcruxVersion': minSimcruxVersion,
      'declaredCapabilities': caps,
    };
    if (authorName != null) map['authorName'] = authorName;
    if (authorContact != null) map['authorContact'] = authorContact;
    if (homepage != null) map['homepage'] = homepage;
    if (repository != null) map['repository'] = repository;
    return map;
  }

  /// Emits a YAML document that round-trips through [fromYaml].
  ///
  /// Output is deterministic — fields are emitted in a fixed order
  /// (top-level identity first, capabilities last) so the manifest
  /// diffs cleanly in version control.
  String toYaml() {
    final buffer = StringBuffer();
    void writeScalar(String key, Object? value) {
      if (value == null) return;
      buffer.writeln('$key: ${_yamlScalar(value)}');
    }

    writeScalar('pluginId', pluginId);
    writeScalar('displayName', displayName);
    writeScalar('description', description);
    writeScalar('version', version);
    writeScalar('authorName', authorName);
    writeScalar('authorContact', authorContact);
    writeScalar('homepage', homepage);
    writeScalar('repository', repository);
    writeScalar('licenseSpdx', licenseSpdx);
    writeScalar('abiVersion', abiVersion);
    writeScalar('executablePath', executablePath);
    writeScalar('stdioProtocol', stdioProtocol.wireId);
    writeScalar('minSimcruxVersion', minSimcruxVersion);

    buffer.writeln('supportedSimulators:');
    for (final entry in supportedSimulators) {
      buffer.writeln('  - ${_yamlScalar(entry)}');
    }
    buffer.writeln('declaredCapabilities:');
    final caps = declaredCapabilities.map((c) => c.wireId).toList()..sort();
    for (final entry in caps) {
      buffer.writeln('  - ${_yamlScalar(entry)}');
    }
    return buffer.toString();
  }

  /// Compact, single-line JSON representation. Useful for cross-tool
  /// pipelines (`simcrux-plugin-info --json`).
  String toJsonString() => _encodeJson(toJson());

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! SimulatorDriverPluginManifest) return false;
    if (pluginId != other.pluginId) return false;
    if (displayName != other.displayName) return false;
    if (description != other.description) return false;
    if (version != other.version) return false;
    if (authorName != other.authorName) return false;
    if (authorContact != other.authorContact) return false;
    if (homepage != other.homepage) return false;
    if (repository != other.repository) return false;
    if (licenseSpdx != other.licenseSpdx) return false;
    if (abiVersion != other.abiVersion) return false;
    if (executablePath != other.executablePath) return false;
    if (stdioProtocol != other.stdioProtocol) return false;
    if (minSimcruxVersion != other.minSimcruxVersion) return false;
    if (supportedSimulators.length != other.supportedSimulators.length) {
      return false;
    }
    for (var i = 0; i < supportedSimulators.length; i++) {
      if (supportedSimulators[i] != other.supportedSimulators[i]) {
        return false;
      }
    }
    if (declaredCapabilities.length != other.declaredCapabilities.length) {
      return false;
    }
    for (final cap in declaredCapabilities) {
      if (!other.declaredCapabilities.contains(cap)) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    pluginId,
    displayName,
    description,
    version,
    authorName,
    authorContact,
    homepage,
    repository,
    licenseSpdx,
    Object.hashAll(supportedSimulators),
    abiVersion,
    executablePath,
    stdioProtocol,
    minSimcruxVersion,
    Object.hashAllUnordered(declaredCapabilities),
  );

  @override
  String toString() => 'SimulatorDriverPluginManifest($pluginId v$version)';
}

/// Sentinel for `copyWith` nullable-field replacement.
const Object _sentinel = Object();

Object? _unwrap(dynamic value) {
  if (value is YamlScalar) return value.value;
  if (value is YamlList) {
    return value.nodes.map(_unwrap).toList(growable: false);
  }
  if (value is YamlMap) {
    final out = <dynamic, dynamic>{};
    value.nodes.forEach((key, val) {
      out[key is YamlScalar ? key.value : key] = _unwrap(val);
    });
    return out;
  }
  return value;
}

String _yamlScalar(Object? value) {
  if (value is int || value is double || value is bool) return '$value';
  final str = value.toString();
  // Quote when the value contains characters that would confuse a
  // YAML parser; the host is conservative and quotes anything that
  // isn't a clean bare scalar.
  final needsQuote =
      str.isEmpty ||
      str.contains(':') ||
      str.contains('#') ||
      str.contains('"') ||
      str.contains("'") ||
      str.contains('\n') ||
      str.contains('  ') ||
      str.trim() != str;
  if (!needsQuote) return str;
  final escaped = str.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  return '"$escaped"';
}

String _encodeJson(Object? value) {
  if (value == null) return 'null';
  if (value is num || value is bool) return '$value';
  if (value is String) {
    final escaped = value
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r')
        .replaceAll('\t', r'\t');
    return '"$escaped"';
  }
  if (value is List) {
    return '[${value.map(_encodeJson).join(',')}]';
  }
  if (value is Map) {
    final parts = <String>[];
    value.forEach((k, v) {
      parts.add('${_encodeJson('$k')}:${_encodeJson(v)}');
    });
    return '{${parts.join(',')}}';
  }
  return _encodeJson('$value');
}

/// Thrown when a manifest cannot be decoded — used by the loader to
/// log a precise diagnostic explaining which manifest failed and why.
///
/// The constructor is intentionally non-const so call sites with
/// interpolated messages do not trigger the analyzer's
/// "prefer-const-constructor" lint.
class SimulatorDriverPluginManifestFormatException implements Exception {
  /// Creates a [SimulatorDriverPluginManifestFormatException].
  SimulatorDriverPluginManifestFormatException(this.message);

  /// Human-readable reason the manifest is malformed.
  final String message;

  @override
  String toString() => 'SimulatorDriverPluginManifestFormatException: $message';
}
