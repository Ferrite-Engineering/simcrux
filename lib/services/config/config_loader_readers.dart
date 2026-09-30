// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

part of 'config_loader.dart';

// Primitive YAML readers shared by every section parser in the
// ConfigLoader library. These are pure functions — they never touch
// loader instance state — so they live as top-level helpers on the
// library rather than methods on [ConfigLoader]. Every section-parser
// part file ([config_loader_pass_fail.dart], [config_loader_sources.dart],
// [config_loader_sweeps.dart], [config_loader_sections.dart]) calls into
// them.

String? _readString(YamlMap map, List<String> path) {
  Object? node = map;
  for (final key in path) {
    if (node is! YamlMap) return null;
    node = node[key];
  }
  if (node is String) return node;
  return null;
}

String? _requireString(
  YamlMap map,
  String key,
  String path,
  List<ConfigLoaderError> errors,
) {
  final raw = map[key];
  if (raw == null) {
    errors.add(
      _error(
        path: path,
        node: map,
        message: 'Missing required field `$key`.',
      ),
    );
    return null;
  }
  if (raw is String) return raw;
  errors.add(
    _error(
      path: path,
      node: map.nodes[key],
      message: 'Field `$key` must be a string, got ${_typeNameOf(raw)}.',
    ),
  );
  return null;
}

List<String>? _readStringList(YamlMap map, List<String> path) {
  Object? node = map;
  for (final key in path) {
    if (node is! YamlMap) return null;
    node = node[key];
  }
  if (node is! YamlList) return null;
  return node.value.whereType<String>().toList(growable: false);
}

Map<String, String>? _readStringMap(
  YamlMap map,
  List<String> path,
  String filePath,
  List<ConfigLoaderError> errors,
) {
  Object? node = map;
  YamlNode? currentNode = map;
  for (final key in path) {
    if (node is! YamlMap) return null;
    currentNode = node.nodes[key];
    node = node[key];
  }
  if (node == null) return null;
  if (node is! YamlMap) {
    errors.add(
      _error(
        path: filePath,
        node: currentNode,
        message: 'Field `${path.join('.')}` must be a map of string to string.',
      ),
    );
    return null;
  }
  final out = <String, String>{};
  for (final entry in node.entries) {
    final k = entry.key;
    final v = entry.value;
    if (k is String && v is String) {
      out[k] = v;
    } else if (k is String && (v is num || v is bool)) {
      out[k] = v.toString();
    } else {
      // Skip silently — the surrounding validator already flagged
      // shape errors. A map with non-string keys is suspect but the
      // most common case (numeric value) is handled above.
    }
  }
  return out;
}

/// Reads a non-negative integer field. Returns null when [raw] is
/// absent (caller supplies its own default); records an error and
/// returns null when the value is present but unparseable / negative.
int? _readNonNegativeInt(
  Object? raw, {
  required String fieldName,
  required String filePath,
  required YamlNode? currentNode,
  required List<ConfigLoaderError> errors,
}) {
  if (raw == null) return null;
  if (raw is int && raw >= 0) return raw;
  errors.add(
    _error(
      path: filePath,
      node: currentNode,
      message:
          'Field `$fieldName` must be a non-negative integer (got `$raw`).',
    ),
  );
  return null;
}

Duration? _readDuration(
  YamlMap map,
  List<String> path,
  String filePath,
  List<ConfigLoaderError> errors,
) {
  Object? node = map;
  YamlNode? currentNode = map;
  for (final key in path) {
    if (node is! YamlMap) return null;
    currentNode = node.nodes[key];
    node = node[key];
  }
  if (node == null) return null;
  if (node is int) return Duration(seconds: node);
  if (node is String) {
    final parsed = _parseDurationString(node);
    if (parsed != null) return parsed;
    errors.add(
      _error(
        path: filePath,
        node: currentNode,
        message:
            'Field `${path.join('.')}`: invalid duration `$node` '
            '(expected `<number>` seconds or `<number>s|ms|m|h`).',
      ),
    );
    return null;
  }
  errors.add(
    _error(
      path: filePath,
      node: currentNode,
      message:
          'Field `${path.join('.')}` must be a duration string (e.g. `30s`, `5m`).',
    ),
  );
  return null;
}

/// Parses a duration of the form `<n>(s|ms|m|h)` or a bare integer
/// (interpreted as seconds for backwards compatibility with early
/// `simcrux.yaml` files). Returns null on parse
/// failure.
Duration? _parseDurationString(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  final match = RegExp(r'^(\d+)(ms|s|m|h)?$').firstMatch(trimmed);
  if (match == null) return null;
  final amount = int.parse(match.group(1)!);
  switch (match.group(2)) {
    case 'ms':
      return Duration(milliseconds: amount);
    case null:
    case '':
    case 's':
      return Duration(seconds: amount);
    case 'm':
      return Duration(minutes: amount);
    case 'h':
      return Duration(hours: amount);
  }
  return null;
}

/// Translates a YAML string like `verilog`, `system_verilog`,
/// `systemverilog`, `vhdl`, `python` into an [HdlLanguage]. Returns
/// `null` for any unrecognized value so the caller can surface a
/// structured error with the offending YAML node.
HdlLanguage? _parseHdlLanguage(String raw) {
  switch (raw.toLowerCase()) {
    case 'verilog':
      return HdlLanguage.verilog;
    case 'systemverilog':
    case 'system_verilog':
    case 'sv':
      return HdlLanguage.systemVerilog;
    case 'vhdl':
    case 'vhd':
      return HdlLanguage.vhdl;
    case 'python':
      return HdlLanguage.python;
    default:
      return null;
  }
}

/// Wraps the path / node / message tuple in a [ConfigLoaderError]
/// with line and column extracted from the node's source span when
/// available.
ConfigLoaderError _error({
  required String path,
  required Object? node,
  required String message,
  ConfigLoaderErrorSeverity severity = ConfigLoaderErrorSeverity.error,
}) {
  if (node is YamlNode) {
    final span = node.span;
    return ConfigLoaderError(
      path: path,
      message: message,
      // YAML spans are 0-based; the standard editor/IDE convention is 1-based.
      line: span.start.line + 1,
      column: span.start.column + 1,
      severity: severity,
    );
  }
  return ConfigLoaderError.generic(
    path: path,
    message: message,
    severity: severity,
  );
}

String _typeNameOf(Object? value) {
  if (value == null) return 'null';
  if (value is String) return 'string';
  if (value is int) return 'int';
  if (value is double) return 'number';
  if (value is bool) return 'bool';
  if (value is YamlList) return 'list';
  if (value is YamlMap) return 'map';
  return value.runtimeType.toString();
}
