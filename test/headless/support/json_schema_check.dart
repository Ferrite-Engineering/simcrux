// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// The JSON Schema keywords the files in `spec/mcp/schemas/` use, checked
/// against a decoded document.
///
/// A small checker rather than a dependency: the schemas use a dozen
/// keywords, and a keyword this does not know fails the check instead of
/// being ignored, so a schema cannot quietly say more than is tested.
library;

const Set<String> _annotations = <String>{
  r'$schema',
  r'$defs',
  'title',
  'description',
};

const Set<String> _keywords = <String>{
  r'$ref',
  'anyOf',
  'const',
  'enum',
  'type',
  'properties',
  'required',
  'additionalProperties',
  'items',
  'maxItems',
  'minimum',
  'pattern',
};

/// Every way [value] breaks [schema], each prefixed by the JSON path where
/// it does; empty when it keeps it. `$ref`s resolve against [schema]'s own
/// `$defs`.
List<String> jsonSchemaProblems(Object? value, Map<String, Object?> schema) {
  final problems = <String>[];
  _check(value, node: schema, root: schema, at: r'$', problems: problems);
  return problems;
}

void _check(
  Object? value, {
  required Map<String, Object?> node,
  required Map<String, Object?> root,
  required String at,
  required List<String> problems,
}) {
  for (final key in node.keys) {
    if (!_keywords.contains(key) && !_annotations.contains(key)) {
      throw ArgumentError('schema keyword `$key` at $at is not checked here');
    }
  }
  final ref = node[r'$ref'];
  if (ref is String) {
    const prefix = r'#/$defs/';
    if (!ref.startsWith(prefix)) throw ArgumentError('unsupported \$ref $ref');
    final defs = root[r'$defs']! as Map<String, Object?>;
    final target = defs[ref.substring(prefix.length)];
    if (target is! Map<String, Object?>) throw ArgumentError('no def $ref');
    _check(value, node: target, root: root, at: at, problems: problems);
  }
  final anyOf = node['anyOf'];
  if (anyOf is List<Object?>) {
    final passes = anyOf.any((option) {
      final local = <String>[];
      _check(
        value,
        node: option! as Map<String, Object?>,
        root: root,
        at: at,
        problems: local,
      );
      return local.isEmpty;
    });
    if (!passes) problems.add('$at matches none of anyOf');
  }
  if (node.containsKey('const') && value != node['const']) {
    problems.add('$at is $value, not ${node['const']}');
  }
  final enumeration = node['enum'];
  if (enumeration is List<Object?> && !enumeration.contains(value)) {
    problems.add('$at is $value, not one of $enumeration');
  }
  final type = node['type'];
  if (type != null) {
    final types = type is List<Object?>
        ? type.cast<String>()
        : <String>[type as String];
    if (!types.any((t) => _isType(value, t))) {
      problems.add('$at is ${value.runtimeType}, not $types');
      return;
    }
  }
  final minimum = node['minimum'];
  if (minimum is num && value is num && value < minimum) {
    problems.add('$at is $value, below $minimum');
  }
  final pattern = node['pattern'];
  if (pattern is String &&
      value is String &&
      !RegExp(pattern).hasMatch(value)) {
    problems.add('$at "$value" does not match $pattern');
  }
  if (value is Map<String, Object?>) {
    final properties =
        (node['properties'] as Map<String, Object?>?) ??
        const <String, Object?>{};
    for (final name in (node['required'] as List<Object?>?) ?? const []) {
      if (!value.containsKey(name)) problems.add('$at has no `$name`');
    }
    for (final entry in value.entries) {
      final sub = properties[entry.key];
      if (sub is Map<String, Object?>) {
        _check(
          entry.value,
          node: sub,
          root: root,
          at: '$at.${entry.key}',
          problems: problems,
        );
      } else if (node['additionalProperties'] == false) {
        problems.add('$at has `${entry.key}`, which the schema does not');
      }
    }
  }
  if (value is List<Object?>) {
    final maxItems = node['maxItems'];
    if (maxItems is int && value.length > maxItems) {
      problems.add('$at has ${value.length} items, past $maxItems');
    }
    final items = node['items'];
    if (items is Map<String, Object?>) {
      for (var i = 0; i < value.length; i++) {
        _check(
          value[i],
          node: items,
          root: root,
          at: '$at[$i]',
          problems: problems,
        );
      }
    }
  }
}

bool _isType(Object? value, String type) => switch (type) {
  'null' => value == null,
  'boolean' => value is bool,
  'integer' => value is int,
  'number' => value is num,
  'string' => value is String,
  'array' => value is List<Object?>,
  'object' => value is Map<String, Object?>,
  _ => throw ArgumentError('unknown type $type'),
};
