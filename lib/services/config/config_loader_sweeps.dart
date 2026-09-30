// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

part of 'config_loader.dart';

/// Parses the `parameters:` block accepting both legacy scalar form
/// (`MEM_SIZE: "1024"`) and sweep form
/// (`MEM_SIZE: ["1024", "4096"]`). Returns the bound scalars and
/// the sweep axes split into two maps.
///
/// Empty list values are rejected with a structured error (the
/// sweep declares "expand over zero choices" which would produce
/// zero specs); single-element lists are normalized into the scalar
/// map because they describe a single bound value.
_SweepableParameters _readSweepableParameters(
  YamlMap map,
  List<String> path,
  String filePath,
  List<ConfigLoaderError> errors,
) {
  Object? node = map;
  YamlNode? currentNode = map;
  for (final key in path) {
    if (node is! YamlMap) {
      return const _SweepableParameters(
        bound: <String, String>{},
        sweeps: <String, List<String>>{},
      );
    }
    currentNode = node.nodes[key];
    node = node[key];
  }
  if (node == null) {
    return const _SweepableParameters(
      bound: <String, String>{},
      sweeps: <String, List<String>>{},
    );
  }
  if (node is! YamlMap) {
    errors.add(
      _error(
        path: filePath,
        node: currentNode,
        message:
            'Field `${path.join('.')}` must be a map of string to string or '
            'list of strings.',
      ),
    );
    return const _SweepableParameters(
      bound: <String, String>{},
      sweeps: <String, List<String>>{},
    );
  }
  final bound = <String, String>{};
  final sweeps = <String, List<String>>{};
  for (final entry in node.entries) {
    final k = entry.key;
    final v = entry.value;
    if (k is! String) continue;
    if (v is String) {
      bound[k] = v;
    } else if (v is num || v is bool) {
      bound[k] = v.toString();
    } else if (v is YamlList) {
      if (v.isEmpty) {
        errors.add(
          _error(
            path: filePath,
            node: node.nodes[k],
            message:
                'Parameter `$k` sweep is empty — declare at least one '
                'value or remove the entry.',
          ),
        );
        continue;
      }
      final values = <String>[];
      for (final element in v) {
        if (element is String) {
          values.add(element);
        } else if (element is num || element is bool) {
          values.add(element.toString());
        } else {
          errors.add(
            _error(
              path: filePath,
              node: node.nodes[k],
              message:
                  'Parameter `$k` sweep entries must be strings, numbers, '
                  'or booleans (got ${_typeNameOf(element)}).',
            ),
          );
        }
      }
      if (values.length == 1) {
        // Single-element sweep is identical to a scalar binding —
        // collapse to the bound map so the expander never fans out
        // a useless single-element axis.
        bound[k] = values.single;
      } else if (values.isNotEmpty) {
        sweeps[k] = values;
      }
    } else {
      errors.add(
        _error(
          path: filePath,
          node: node.nodes[k],
          message:
              'Parameter `$k` value must be a string, number, boolean, '
              'or a list of those (got ${_typeNameOf(v)}).',
        ),
      );
    }
  }
  return _SweepableParameters(bound: bound, sweeps: sweeps);
}

/// Reads a `seeds:` field. Must be a YAML list — either of non-negative
/// integers (`seeds: [1, 2, 3]`) or containing a "range shorthand" string
/// element (`seeds: ["1..10"]`). A bare string (`seeds: "1..10"`) is *not*
/// accepted.
///
/// Returns `null` when the field is absent. Range shorthand expands
/// inclusively (`1..3` → `[1, 2, 3]`).
List<int>? _readSeedsField(
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
  if (node is! YamlList) {
    errors.add(
      _error(
        path: filePath,
        node: currentNode,
        message:
            'Field `${path.join('.')}` must be a list of non-negative '
            'integers (e.g. `seeds: [1, 2, 3]`) or a range shorthand '
            '(e.g. `seeds: ["1..10"]`).',
      ),
    );
    return null;
  }
  if (node.isEmpty) {
    errors.add(
      _error(
        path: filePath,
        node: currentNode,
        message:
            'Field `${path.join('.')}` is empty — declare at least one '
            'seed or remove the entry.',
      ),
    );
    return null;
  }
  final out = <int>[];
  for (final element in node) {
    if (element is int) {
      if (element < 0) {
        errors.add(
          _error(
            path: filePath,
            node: currentNode,
            message:
                'Seed values must be non-negative integers (got $element).',
          ),
        );
        continue;
      }
      out.add(element);
    } else if (element is String) {
      final expanded = _expandSeedRangeShorthand(
        raw: element,
        filePath: filePath,
        currentNode: currentNode,
        errors: errors,
      );
      if (expanded != null) out.addAll(expanded);
    } else {
      errors.add(
        _error(
          path: filePath,
          node: currentNode,
          message:
              'Field `${path.join('.')}` entries must be non-negative '
              'integers or `"<low>..<high>"` range strings '
              '(got ${_typeNameOf(element)}).',
        ),
      );
    }
  }
  if (out.isEmpty) return null;
  return out;
}

/// Expands a `"<low>..<high>"` range shorthand into an inclusive
/// integer list. Returns null when the input fails to match the
/// expected form; records a structured error on the caller's
/// behalf.
List<int>? _expandSeedRangeShorthand({
  required String raw,
  required String filePath,
  required YamlNode? currentNode,
  required List<ConfigLoaderError> errors,
}) {
  final trimmed = raw.trim();
  final match = RegExp(r'^(\d+)\.\.(\d+)$').firstMatch(trimmed);
  if (match == null) {
    errors.add(
      _error(
        path: filePath,
        node: currentNode,
        message:
            'Seed range shorthand `$raw` is malformed (expected '
            '`"<low>..<high>"` with non-negative integers).',
      ),
    );
    return null;
  }
  final low = int.parse(match.group(1)!);
  final high = int.parse(match.group(2)!);
  if (low > high) {
    errors.add(
      _error(
        path: filePath,
        node: currentNode,
        message:
            'Seed range shorthand `$raw`: low ($low) must be <= high '
            '($high).',
      ),
    );
    return null;
  }
  return [for (var i = low; i <= high; i++) i];
}

/// Reads a scalar `seed: 42` field. Returns null when the field is
/// absent. Records a structured error and returns null when the
/// value is the wrong shape or negative.
int? _readScalarSeedField(
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
  if (node is int && node >= 0) return node;
  errors.add(
    _error(
      path: filePath,
      node: currentNode,
      message:
          'Field `${path.join('.')}` must be a non-negative integer '
          '(got `$node`).',
    ),
  );
  return null;
}

/// Private return type of [_readSweepableParameters]: the scalar
/// (single-bound) parameter values and the sweep axes, split into two
/// maps so the caller can route them into the right [TestSpec] fields
/// without re-walking the YAML node.
class _SweepableParameters {
  const _SweepableParameters({
    required this.bound,
    required this.sweeps,
  });

  /// Scalar single-bound parameter values (`MEM_SIZE: "1024"`).
  final Map<String, String> bound;

  /// Multi-value sweep axes (`MEM_SIZE: ["1024", "4096"]`). Single-
  /// element sweeps are folded into [bound] by the reader, so every
  /// entry here has at least two distinct values.
  final Map<String, List<String>> sweeps;
}
