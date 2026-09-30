// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

part of 'config_loader.dart';

// Pass/fail-detector section parser. Unlike the other section readers
// these need the loader's reusable-detector catalog (for the `use:`
// form and its cycle check), so [reusableDetectors] is threaded in as a
// parameter rather than read from instance state.

PassFailConfig? _readPassFailConfig(
  YamlMap map,
  List<String> path,
  String filePath,
  List<ConfigLoaderError> errors, {
  required Map<String, DetectorSpec> reusableDetectors,
}) {
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
        message: '`${path.join('.')}` must be a map with a `type` field.',
      ),
    );
    return null;
  }
  final type = node['type'];
  switch (type) {
    case 'exit_code':
      return const ExitCodePassFailConfig();
    case 'string_match':
      final label = path.isEmpty ? 'pass_fail' : path.join('.');
      final before = errors.length;
      final passString = _readDetectorString(
        node,
        'pass_string',
        label,
        filePath,
        errors,
      );
      final failString = _readDetectorString(
        node,
        'fail_string',
        label,
        filePath,
        errors,
      );
      // A mistyped field has already said so, at its own line; the
      // "requires at least one" below would only repeat it less precisely.
      if (errors.length > before) return null;
      if (passString == null && failString == null) {
        errors.add(
          _error(
            path: filePath,
            node: currentNode,
            message:
                '`${path.join('.')}` (string_match) requires at least one of '
                '`pass_string` / `fail_string`.',
          ),
        );
        return null;
      }
      return StringMatchPassFailConfig(
        passString: passString,
        failString: failString,
      );
    case 'regex':
      final label = path.isEmpty ? 'pass_fail' : path.join('.');
      final before = errors.length;
      final passPattern = _readDetectorString(
        node,
        'pass_pattern',
        label,
        filePath,
        errors,
      );
      final failPattern = _readDetectorString(
        node,
        'fail_pattern',
        label,
        filePath,
        errors,
      );
      if (errors.length > before) return null;
      if (passPattern == null && failPattern == null) {
        errors.add(
          _error(
            path: filePath,
            node: currentNode,
            message:
                '`${path.join('.')}` (regex) requires at least one of '
                '`pass_pattern` / `fail_pattern`.',
          ),
        );
        return null;
      }
      var patternsValid = true;
      for (final (key, pattern) in [
        ('pass_pattern', passPattern),
        ('fail_pattern', failPattern),
      ]) {
        final problem = _regexCompileProblem(pattern);
        if (problem == null) continue;
        patternsValid = false;
        errors.add(
          _error(
            path: filePath,
            node: node.nodes[key] ?? currentNode,
            message: _invalidRegexMessage('$label.$key', pattern!, problem),
          ),
        );
      }
      if (!patternsValid) return null;
      return RegexPassFailConfig(
        passPattern: passPattern,
        failPattern: failPattern,
      );
    case 'cocotb':
      // `allow_no_tests` is the only knob: everything else about a Cocotb
      // verdict is dictated by the summary line, and inventing thresholds it
      // does not report would be configuration that cannot be honoured.
      final allowNoTests = node['allow_no_tests'];
      if (allowNoTests != null && allowNoTests is! bool) {
        errors.add(
          _error(
            path: filePath,
            node: currentNode,
            message:
                '`${path.join('.')}.allow_no_tests` (cocotb) must be a '
                'boolean.',
          ),
        );
        return null;
      }
      return CocotbPassFailConfig(allowNoTests: allowNoTests == true);
    case 'uvm_report':
      final fatal = _readNonNegativeInt(
        node['fatal_threshold'],
        fieldName: '${path.join('.')}.fatal_threshold',
        filePath: filePath,
        currentNode: currentNode,
        errors: errors,
      );
      final err = _readNonNegativeInt(
        node['error_threshold'],
        fieldName: '${path.join('.')}.error_threshold',
        filePath: filePath,
        currentNode: currentNode,
        errors: errors,
      );
      final warn = _readNonNegativeInt(
        node['warning_threshold'],
        fieldName: '${path.join('.')}.warning_threshold',
        filePath: filePath,
        currentNode: currentNode,
        errors: errors,
      );
      return UvmReportPassFailConfig(
        fatalThreshold: fatal ?? 1,
        errorThreshold: err ?? 1,
        warningThreshold: warn,
      );
    case 'golden_compare':
      return _readGoldenCompareConfig(
        node,
        path,
        filePath,
        currentNode,
        errors,
      );
    case 'composite':
      final allOfNode = node['all_of'];
      final anyOfNode = node['any_of'];
      final allOf = <PassFailConfig>[];
      final anyOf = <PassFailConfig>[];
      if (allOfNode is YamlList) {
        for (var i = 0; i < allOfNode.length; i++) {
          final child = _readPassFailFromNode(
            allOfNode[i],
            filePath,
            errors,
            reusableDetectors: reusableDetectors,
          );
          if (child != null) allOf.add(child);
        }
      }
      if (anyOfNode is YamlList) {
        for (var i = 0; i < anyOfNode.length; i++) {
          final child = _readPassFailFromNode(
            anyOfNode[i],
            filePath,
            errors,
            reusableDetectors: reusableDetectors,
          );
          if (child != null) anyOf.add(child);
        }
      }
      if (allOf.isEmpty && anyOf.isEmpty) {
        errors.add(
          _error(
            path: filePath,
            node: currentNode,
            message:
                '`${path.join('.')}` (composite) requires at least one of '
                '`all_of` / `any_of`.',
          ),
        );
        return null;
      }
      return CompositePassFailConfig(allOf: allOf, anyOf: anyOf);
    case 'use':
      final name = node['name'];
      if (name is! String || name.isEmpty) {
        errors.add(
          _error(
            path: filePath,
            node: currentNode,
            message:
                '`${path.join('.')}` (use) requires a non-empty '
                '`name` field.',
          ),
        );
        return null;
      }
      final target = reusableDetectors[name];
      if (target == null) {
        errors.add(
          _error(
            path: filePath,
            node: currentNode,
            message:
                '`${path.join('.')}` (use) references unknown reusable '
                'detector "$name". Library detectors live in the SimCrux '
                'app under Settings > Detectors: define it there. '
                "`simcrux --ci` never reads the app's settings, so for a "
                'CI run replace `type: use` with the detector itself in '
                'the project file.',
          ),
        );
        return null;
      }
      final cycle = _detectDetectorCycle(name, reusableDetectors);
      if (cycle != null) {
        errors.add(
          _error(
            path: filePath,
            node: currentNode,
            message:
                '`${path.join('.')}` (use "$name"): cycle detected '
                '($cycle).',
          ),
        );
        return null;
      }
      final resolved = DetectorSpec.resolve(target, reusableDetectors);
      // A library detector is authored in Settings, where nothing compiles
      // its patterns — so check them here, where the project that uses it
      // loads, rather than let the test classify on the exit code alone.
      final invalid = resolved == null ? null : _firstInvalidRegex(resolved);
      if (invalid != null) {
        errors.add(
          _error(
            path: filePath,
            node: currentNode,
            message: _invalidRegexMessage(
              '`${path.join('.')}` (use "$name")',
              invalid.pattern,
              invalid.problem,
              labelIsQuoted: true,
            ),
          ),
        );
        return null;
      }
      return resolved;
    default:
      errors.add(
        _error(
          path: filePath,
          node: currentNode,
          message:
              '`${path.join('.')}.type` must be one of '
              'exit_code, string_match, regex, uvm_report, cocotb, '
              'golden_compare, composite, use (got "$type").',
        ),
      );
      return null;
  }
}

/// Reads an optional string field of a detector: null when absent, the
/// string when it is one, and an error at the value's own line and column
/// when it is anything else.
///
/// `pass_string: 200` is the case this exists for. YAML reads the unquoted
/// number as an int, and a cast here used to throw a `TypeError` that
/// escaped the loader with no file, line or column. The error names the
/// type and the fix rather than stringifying the value, because the parsed
/// number is not always the text the user typed (`0x10` reads as 16), so
/// the suggested fix quotes the source text itself.
String? _readDetectorString(
  YamlMap node,
  String key,
  String label,
  String filePath,
  List<ConfigLoaderError> errors,
) {
  final raw = node[key];
  if (raw == null) return null;
  if (raw is String) return raw;
  final valueNode = node.nodes[key];
  final hint = (raw is num || raw is bool)
      ? " Quote it if it is meant as text: `$key: '${valueNode?.span.text ?? raw}'`."
      : '';
  errors.add(
    _error(
      path: filePath,
      node: valueNode,
      message: '`$label.$key` must be a string, got ${_typeNameOf(raw)}.$hint',
    ),
  );
  return null;
}

PassFailConfig? _readPassFailFromNode(
  Object? raw,
  String filePath,
  List<ConfigLoaderError> errors, {
  required Map<String, DetectorSpec> reusableDetectors,
}) {
  if (raw is! YamlMap) {
    errors.add(
      ConfigLoaderError.generic(
        path: filePath,
        message: 'Composite child must be a pass/fail map.',
      ),
    );
    return null;
  }
  return _readPassFailConfig(
    raw,
    const <String>[], // already at the leaf
    filePath,
    errors,
    reusableDetectors: reusableDetectors,
  );
}

// ── golden_compare ────────────────────────────────────────────────
//
// The seventh YAML `type:`. Architecture neutral by design: RISC-V
// architectural signatures are the flagship use but arrive as a
// `profile:`, not as the type (see `GoldenCompareProfile`).
//
// Deliberately **not** tier-gated, here or anywhere downstream —
// including after `kBetaPeriod` flips. The loader's existing
// `_parameterizationUnlocked` gate covers `seeds:` / `parameters:`
// sweeps, which are a productivity feature and therefore Pro; a
// compatibility verdict is correctness and is free.
// The asymmetry is intentional — do not "fix" it by adding a gate.
PassFailConfig? _readGoldenCompareConfig(
  YamlMap node,
  List<String> path,
  String filePath,
  YamlNode? currentNode,
  List<ConfigLoaderError> errors,
) {
  final label = path.isEmpty ? 'pass_fail' : path.join('.');

  final profileRaw = node['profile'];
  var profile = GoldenCompareProfile.generic;
  if (profileRaw != null) {
    final parsed = GoldenCompareProfile.fromWireName(profileRaw);
    if (parsed == null) {
      errors.add(
        _error(
          path: filePath,
          node: currentNode,
          message:
              '`$label.profile` must be one of '
              '${GoldenCompareProfile.wireNames.join(', ')} '
              '(got "$profileRaw").',
        ),
      );
      return null;
    }
    profile = parsed;
  }

  final dut = _readGoldenPath(
    node['dut'],
    fieldName: '$label.dut',
    fallback: profile.defaultDutPath,
    profile: profile,
    filePath: filePath,
    currentNode: currentNode,
    errors: errors,
  );
  final reference = _readGoldenPath(
    node['reference'],
    fieldName: '$label.reference',
    fallback: profile.defaultReferencePath,
    profile: profile,
    filePath: filePath,
    currentNode: currentNode,
    errors: errors,
  );
  if (dut == null || reference == null) return null;

  if (dut == reference) {
    errors.add(
      _error(
        path: filePath,
        node: currentNode,
        message:
            '`$label` (golden_compare) points `dut` and `reference` at the '
            'same file ("$dut"), which would always pass. Give the golden '
            'a distinct path.',
      ),
    );
    return null;
  }

  return GoldenComparePassFailConfig(
    dutPath: dut,
    referencePath: reference,
    profile: profile,
  );
}

/// Reads one `golden_compare` path field, falling back to the profile's
/// conventional filename. Adds an error and returns null when the value
/// is present-but-unusable, or absent with no convention to fall back on.
String? _readGoldenPath(
  Object? raw, {
  required String fieldName,
  required String? fallback,
  required GoldenCompareProfile profile,
  required String filePath,
  required YamlNode? currentNode,
  required List<ConfigLoaderError> errors,
}) {
  if (raw == null) {
    if (fallback != null) return fallback;
    errors.add(
      _error(
        path: filePath,
        node: currentNode,
        message:
            '`$fieldName` is required: the `${profile.wireName}` profile '
            'has no conventional filename to fall back on.',
      ),
    );
    return null;
  }
  if (raw is! String || raw.isEmpty) {
    errors.add(
      _error(
        path: filePath,
        node: currentNode,
        message: '`$fieldName` must be a non-empty file path.',
      ),
    );
    return null;
  }
  return raw;
}

/// Returns why [pattern] does not compile as a Dart `RegExp`, or null when it
/// compiles (or is absent).
///
/// An uncompilable pattern must fail the load. The detector itself can only
/// return `unknown` for it, and the scheduler then adopts the driver's status
/// — so a `fail_pattern` that never compiles turns a failing test that exits
/// 0 into a pass, the opposite of what its author wrote.
String? _regexCompileProblem(String? pattern) {
  if (pattern == null || pattern.isEmpty) return null;
  try {
    RegExp(pattern, multiLine: true);
    return null;
  } on FormatException catch (e) {
    return e.message;
  }
}

String _invalidRegexMessage(
  String field,
  String pattern,
  String problem, {
  bool labelIsQuoted = false,
}) {
  final label = labelIsQuoted ? field : '`$field`';
  final hint = RegExp(r'\(\?[A-Za-z-]+\)').hasMatch(pattern)
      ? ' Dart regular expressions have no inline flag group such as '
            '`(?i)`; wrap the case-insensitive part as `(?i:…)` or use a '
            'character class.'
      : '';
  return '$label is not a valid regular expression ($problem): '
      '"$pattern".$hint';
}

/// The first regex pattern in [config] (walking composites) that does not
/// compile, or null when every pattern compiles.
({String pattern, String problem})? _firstInvalidRegex(PassFailConfig config) {
  switch (config) {
    case RegexPassFailConfig(:final passPattern, :final failPattern):
      for (final pattern in [failPattern, passPattern]) {
        final problem = _regexCompileProblem(pattern);
        if (problem != null) return (pattern: pattern!, problem: problem);
      }
      return null;
    case CompositePassFailConfig(:final allOf, :final anyOf):
      for (final child in [...allOf, ...anyOf]) {
        final invalid = _firstInvalidRegex(child);
        if (invalid != null) return invalid;
      }
      return null;
    default:
      return null;
  }
}

/// Detects a reference cycle in the reusable-detector graph starting
/// at [name]. Returns a printable cycle path (e.g.
/// `"a" → "b" → "a"`) if a cycle is found, or null when the graph
/// is acyclic from this entry point.
String? _detectDetectorCycle(
  String name,
  Map<String, DetectorSpec> reusable,
) {
  final stack = <String>[];
  String? walk(String current) {
    if (stack.contains(current)) {
      return [...stack, current].map((s) => '"$s"').join(' → ');
    }
    final target = reusable[current];
    if (target == null) return null;
    stack.add(current);
    try {
      return _walkSpec(target, reusable, stack, walk);
    } finally {
      stack.removeLast();
    }
  }

  return walk(name);
}

String? _walkSpec(
  DetectorSpec spec,
  Map<String, DetectorSpec> reusable,
  List<String> stack,
  String? Function(String) walk,
) {
  switch (spec) {
    case ExitCodeSpec():
    case StringMatchSpec():
    case RegexSpec():
    case UvmReportSpec():
    case CocotbSpec():
    case GoldenCompareSpec():
      return null;
    case CompositeSpec(:final allOf, :final anyOf):
      for (final child in [...allOf, ...anyOf]) {
        final cycle = _walkSpec(child, reusable, stack, walk);
        if (cycle != null) return cycle;
      }
      return null;
    case UseSpec(:final name):
      return walk(name);
  }
}
