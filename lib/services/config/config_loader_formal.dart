// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

part of 'config_loader.dart';

// ── the general `formal:` block (the `sby` driver) ─────────────────────
//
// Read at the same four inheritance levels as `riscv:` and merged with
// `FormalConfig.mergeOnto`. Never tier-gated, for the reason recorded at the
// top of `config_loader_riscv.dart`: a verdict is correctness and is free.
//
// The project-tooling gate, one behaviour per kind of key:
//
// - `formal.command` and `formal.extra_args` are argv the driver spawns
//   verbatim. With the gate closed the load is refused: running a different
//   invocation than the file asked for is worse than one clear diagnostic.
// - `formal.sby_binary`, `formal.eqy_binary`, `formal.ghdl_binary` and every
//   `formal.tools.<tool>` choose an executable and each has a safe default (the conventional name
//   on PATH, or no `--<tool>` option at all). With the gate closed they are
//   dropped, with one advisory per block naming every dropped key.

/// The `formal:` keys this reader knows. Anything else is an error, so a
/// misspelt `sby_bianry` cannot silently fall back to PATH.
const Set<String> _kFormalKeys = <String>{
  'sby_file',
  'task',
  'sby_binary',
  'eqy_file',
  'eqy_binary',
  'ghdl_binary',
  'command',
  'extra_args',
  'tools',
  'mode',
  'demo_outputs',
  'demo_case',
};

FormalConfig? _readFormalConfig(
  YamlMap map,
  List<String> path,
  String filePath,
  List<ConfigLoaderError> errors, {
  required bool allowTooling,
}) {
  Object? node = map;
  YamlNode? currentNode = map;
  for (final key in path) {
    if (node is! YamlMap) return null;
    currentNode = node.nodes[key];
    node = node[key];
  }
  if (node == null) return null;
  final label = path.join('.');
  if (node is! YamlMap) {
    errors.add(
      _error(
        path: filePath,
        node: currentNode,
        message: '`$label` must be a map.',
      ),
    );
    return null;
  }

  for (final keyNode in node.nodes.keys) {
    final key = keyNode is YamlNode ? keyNode.value : keyNode;
    if (key is String && _kFormalKeys.contains(key)) continue;
    errors.add(
      _error(
        path: filePath,
        node: keyNode is YamlNode ? keyNode : currentNode,
        message:
            '`$label.$key` is not a formal key. Known keys: '
            '${(_kFormalKeys.toList()..sort()).join(', ')}.',
      ),
    );
  }

  if (!allowTooling) {
    for (final key in const <String>['command', 'extra_args']) {
      if (node[key] == null) continue;
      errors.add(
        _error(
          path: filePath,
          node: node.nodes[key],
          message:
              '`$label.$key` is part of the command line SimCrux spawns, '
              'which a project file may not choose on its own. '
              '$kProjectToolingRemedy',
        ),
      );
    }
  }

  final gate = _ProjectExecutableGate(allowTooling: allowTooling);
  final config = FormalConfig(
    sbyFile: _readFormalSbyFile(node, label, filePath, errors),
    task: _readFormalTask(node, label, filePath, errors),
    sbyBinary: gate.read(node, 'sby_binary', label, filePath, errors),
    eqyFile: _readFormalEqyFile(node, label, filePath, errors),
    eqyBinary: gate.read(node, 'eqy_binary', label, filePath, errors),
    ghdlBinary: gate.read(node, 'ghdl_binary', label, filePath, errors),
    command: _readRiscvStringList(node, 'command', label, filePath, errors),
    extraArgs: _readRiscvStringList(
      node,
      'extra_args',
      label,
      filePath,
      errors,
    ),
    tools: _readFormalTools(node, label, filePath, errors, gate),
    mode: _readFormalMode(node, label, filePath, errors),
    demoOutputs: _readRiscvString(
      node,
      'demo_outputs',
      label,
      filePath,
      errors,
    ),
    demoCase: _readFormalDemoCase(node, label, filePath, errors),
  );
  if (gate.dropped.isNotEmpty) {
    final keys = gate.dropped.map((d) => '`${d.key}`').join(', ');
    errors.add(
      _error(
        path: filePath,
        node: gate.dropped.first.node,
        severity: ConfigLoaderErrorSeverity.warning,
        message:
            'Ignored $keys: a project file may not choose which program '
            'SimCrux runs. The conventional executable names are looked up '
            'on PATH instead. $kProjectToolingRemedy',
      ),
    );
  }
  return config;
}

/// Appends one error per completeness problem on the flattened block, for
/// tests that run under the `sby` or `eqy` driver. A `formal:` block on any
/// other simulator is inert, never an error.
void _validateFormalForTest({
  required FormalConfig? formal,
  required String simulatorId,
  required String suiteName,
  required String testName,
  required String filePath,
  required YamlNode? testNode,
  required List<ConfigLoaderError> errors,
}) {
  final List<String> problems;
  if (simulatorId == FormalConfig.kSbySimulatorId) {
    problems = formal == null
        ? const <String>['a `formal:` block with `sby_file` is required.']
        : formal.validateForRun();
  } else if (simulatorId == FormalConfig.kEqySimulatorId) {
    problems = formal == null
        ? const <String>['a `formal:` block with `eqy_file` is required.']
        : formal.validateForEqyRun();
  } else {
    return;
  }
  for (final problem in problems) {
    errors.add(
      _error(
        path: filePath,
        node: testNode,
        message: 'Test `$suiteName/$testName`: $problem',
      ),
    );
  }
}

/// `formal.sby_file`, refusing a value `sby` would read as a flag (the
/// same rule as `riscv.formal.sby_file`).
String? _readFormalSbyFile(
  YamlMap node,
  String label,
  String filePath,
  List<ConfigLoaderError> errors,
) => _readRiscvSbyFile(node, label, filePath, errors);

/// `formal.eqy_file`: refused when `eqy` would read it as a flag, and when
/// its basename cannot name the work directory `eqy -f -d` deletes and
/// recreates.
String? _readFormalEqyFile(
  YamlMap node,
  String label,
  String filePath,
  List<ConfigLoaderError> errors,
) {
  final value = _readRiscvString(node, 'eqy_file', label, filePath, errors);
  if (value == null) return null;
  String? problem;
  if (value.startsWith('-') || value.contains('\n') || value.contains('\r')) {
    problem =
        'it would reach EQY as a flag rather than a file. Write it as '
        '`./$value` if that really is its name';
  } else {
    final segment = FormalContainment.segmentProblem(
      p.basenameWithoutExtension(value),
    );
    if (segment != null) {
      problem =
          'its name cannot name the EQY work directory ($segment), which '
          '`eqy -f -d` deletes and recreates';
    }
  }
  if (problem == null) return value;
  errors.add(
    _error(
      path: filePath,
      node: node.nodes['eqy_file'],
      message:
          '`$label.eqy_file` "${value.replaceAll('\n', r'\n')}": $problem.',
    ),
  );
  return null;
}

/// `formal.task`: a SymbiYosys task name that is also one safe path
/// segment, because it names the directory `sby -f -d` deletes.
String? _readFormalTask(
  YamlMap node,
  String label,
  String filePath,
  List<ConfigLoaderError> errors,
) {
  final value = _readRiscvTaskName(node, label, filePath, errors);
  if (value == null) return null;
  final problem = FormalContainment.segmentProblem(value);
  if (problem == null) return value;
  errors.add(
    _error(
      path: filePath,
      node: node.nodes['task'],
      message:
          '`$label.task` "$value" cannot name a task directory ($problem). '
          '`sby -f -d` deletes and recreates that directory, so it must be a '
          "single name inside the test's working directory.",
    ),
  );
  return null;
}

/// `formal.demo_case`: one safe path segment under `demo_outputs`.
String? _readFormalDemoCase(
  YamlMap node,
  String label,
  String filePath,
  List<ConfigLoaderError> errors,
) {
  final value = _readRiscvString(node, 'demo_case', label, filePath, errors);
  if (value == null) return null;
  final problem = FormalContainment.segmentProblem(value);
  if (problem == null) return value;
  errors.add(
    _error(
      path: filePath,
      node: node.nodes['demo_case'],
      message:
          '`$label.demo_case` must be a single directory name under '
          '`demo_outputs` ($problem).',
    ),
  );
  return null;
}

FormalRunMode? _readFormalMode(
  YamlMap node,
  String label,
  String filePath,
  List<ConfigLoaderError> errors,
) {
  final raw = node['mode'];
  if (raw == null) return null;
  final parsed = FormalRunMode.fromWireName(raw);
  if (parsed != null) return parsed;
  errors.add(
    _error(
      path: filePath,
      node: node.nodes['mode'],
      message:
          '`$label.mode` must be one of '
          '${FormalRunMode.wireNames.join(', ')} (got "$raw").',
    ),
  );
  return null;
}

/// `formal.tools`: a map of [FormalConfig.kToolKeys] to executable paths.
/// Every entry goes through the gate.
Map<String, String>? _readFormalTools(
  YamlMap parent,
  String label,
  String filePath,
  List<ConfigLoaderError> errors,
  _ProjectExecutableGate gate,
) {
  final node = _riscvSubMap(parent, 'tools', label, filePath, errors);
  if (node == null) return null;
  final out = <String, String>{};
  for (final keyNode in node.nodes.keys) {
    final key = keyNode is YamlNode ? keyNode.value : keyNode;
    if (key is! String || !FormalConfig.kToolKeys.contains(key)) {
      errors.add(
        _error(
          path: filePath,
          node: keyNode is YamlNode ? keyNode : null,
          message:
              '`$label.tools.$key` is not an sby tool option. Known tools: '
              '${FormalConfig.kToolKeys.join(', ')}.',
        ),
      );
      continue;
    }
    final value = gate.read(node, key, '$label.tools', filePath, errors);
    if (value != null) out[key] = value;
  }
  return out.isEmpty ? null : out;
}
