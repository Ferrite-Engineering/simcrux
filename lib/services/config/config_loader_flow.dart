// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

part of 'config_loader.dart';

// ── the top-level `flow:` block (implementation flows) ──────────────────
//
// Read from the project file and from every included file; the loader
// concatenates the blocks after includes are merged and synthesises one
// `flow` suite from the entries (`FlowRunImporter`). Never inherited through
// `defaults:` or a suite, and never tier-gated: a flow verdict is
// correctness and is free.
//
// Strict: an unknown key, a key that belongs to the other kind of entry, or
// a value of the wrong shape is an error, so a misspelt `launcer` cannot
// silently fall back to a default.
//
// The project-tooling gate, one behaviour per kind of key:
//
// - `fusesoc` (its core and target become `fusesoc run` argv),
//   `extra_args` (appended to the nextpnr command line) and `handoff` (a
//   viewer's whole command line) are argv. With the gate closed the load is
//   refused.
// - `launcher`, `librelane_binary`, `docker_image` and `fusesoc.binary`
//   choose the executable SimCrux spawns and each has a safe default (the
//   Settings choice, or the conventional name on PATH). With the gate closed
//   they are dropped, with one advisory per block naming every dropped key.

const Set<String> _kFlowKeys = <String>{'entries', 'ingest'};

const Set<String> _kFlowCommonEntryKeys = <String>{'name', 'kind', 'handoff'};

const Set<String> _kFlowLibrelaneKeys = <String>{
  'config',
  'launcher',
  'librelane_binary',
  'docker_image',
  'pdk',
  'tag_prefix',
  'gls',
  'equiv',
};

const Set<String> _kFlowNextpnrKeys = <String>{
  'family',
  'device',
  'package',
  'constraints',
  'top',
  'sources',
  'freq_mhz',
  'detailed_timing',
  'fusesoc',
  'extra_args',
};

/// The nextpnr keys a FuseSoC entry may not set: FuseSoC builds the core
/// with its own synthesis and place-and-route options.
const Set<String> _kFlowNextpnrBuildKeys = <String>{
  'family',
  'device',
  'package',
  'constraints',
  'top',
  'sources',
  'freq_mhz',
  'detailed_timing',
  'extra_args',
};

const Set<String> _kFlowGlsKeys = <String>{
  'tests',
  'netlist',
  'strict_x',
  'clock',
};

const Set<String> _kFlowEquivKeys = <String>{
  'partition_timeout_s',
  'accept_blackbox',
};

const Set<String> _kFlowFusesocKeys = <String>{'core', 'target', 'binary'};

/// An entry name, a tag prefix or a PDK name: letters, digits, `_`, `.` and
/// `-`, so it is one safe path segment and a stable test id on every host.
final RegExp _kFlowSafeName = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$');

/// A HDL top-module identifier.
final RegExp _kFlowIdentifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_$]*$');

FlowConfig? _readFlowConfig(
  YamlMap root,
  String filePath,
  List<ConfigLoaderError> errors, {
  required bool allowTooling,
}) {
  final node = root.nodes['flow'];
  if (node == null) return null;
  if (node is! YamlMap) {
    errors.add(
      _error(path: filePath, node: node, message: '`flow` must be a map.'),
    );
    return null;
  }
  _rejectUnknownKeys(node, _kFlowKeys, 'flow', filePath, errors);

  final entries = <FlowEntry>[];
  final names = <String>{};
  final entriesNode = node.nodes['entries'];
  if (entriesNode != null) {
    if (entriesNode is! YamlList) {
      errors.add(
        _error(
          path: filePath,
          node: entriesNode,
          message: '`flow.entries` must be a list of entries.',
        ),
      );
    } else {
      for (final (index, entryNode) in entriesNode.nodes.indexed) {
        final label = 'flow.entries[$index]';
        if (entryNode is! YamlMap) {
          errors.add(
            _error(
              path: filePath,
              node: entryNode,
              message: '`$label` must be a map.',
            ),
          );
          continue;
        }
        final entry = _readFlowEntry(
          entryNode,
          label,
          filePath,
          errors,
          allowTooling: allowTooling,
        );
        if (entry == null) continue;
        if (!names.add(entry.name)) {
          errors.add(
            _error(
              path: filePath,
              node: entryNode.nodes['name'],
              message:
                  'Flow entry `${entry.name}` is declared twice. Entry names '
                  'are test ids and must be unique.',
            ),
          );
          continue;
        }
        entries.add(entry);
      }
    }
  }

  final ingest = <String>[];
  final ingestNode = node.nodes['ingest'];
  if (ingestNode != null) {
    if (ingestNode is! YamlList) {
      errors.add(
        _error(
          path: filePath,
          node: ingestNode,
          message:
              '`flow.ingest` must be a list of run directories and '
              '`report.json` files.',
        ),
      );
    } else {
      for (final item in ingestNode.nodes) {
        final value = item.value;
        if (value is String &&
            value.trim().isNotEmpty &&
            !value.contains('\x00')) {
          ingest.add(value);
        } else {
          errors.add(
            _error(
              path: filePath,
              node: item,
              message: '`flow.ingest` entries must be non-empty paths.',
            ),
          );
        }
      }
    }
  }
  return FlowConfig(entries: entries, ingest: ingest);
}

FlowEntry? _readFlowEntry(
  YamlMap node,
  String label,
  String filePath,
  List<ConfigLoaderError> errors, {
  required bool allowTooling,
}) {
  final errorCount = errors.length;
  final name = _readFlowSafeName(node, 'name', label, filePath, errors);
  if (name == null && node['name'] == null) {
    errors.add(
      _error(
        path: filePath,
        node: node,
        message: '`$label.name` is required.',
      ),
    );
  }
  final shownLabel = name == null ? label : 'flow entry `$name`';

  final kindRaw = node['kind'];
  FlowKind? kind;
  if (kindRaw == null) {
    errors.add(
      _error(
        path: filePath,
        node: node,
        message: '`$label.kind` is required: librelane or nextpnr.',
      ),
    );
  } else {
    for (final value in FlowKind.values) {
      if (value.wireName == kindRaw) kind = value;
    }
    if (kind == null) {
      errors.add(
        _error(
          path: filePath,
          node: node.nodes['kind'],
          message:
              '`$label.kind` must be librelane or nextpnr (got "$kindRaw").',
        ),
      );
    }
  }

  final ownKeys = switch (kind) {
    FlowKind.librelane => _kFlowLibrelaneKeys,
    FlowKind.nextpnr => _kFlowNextpnrKeys,
    null => <String>{..._kFlowLibrelaneKeys, ..._kFlowNextpnrKeys},
  };
  for (final keyNode in node.nodes.keys) {
    final key = keyNode is YamlNode ? keyNode.value : keyNode;
    if (key is String &&
        (_kFlowCommonEntryKeys.contains(key) || ownKeys.contains(key))) {
      continue;
    }
    final otherKind =
        key is String &&
        (_kFlowLibrelaneKeys.contains(key) || _kFlowNextpnrKeys.contains(key));
    errors.add(
      _error(
        path: filePath,
        node: keyNode is YamlNode ? keyNode : node,
        message: otherKind
            ? '`$label.$key` does not apply to a ${kind?.wireName} entry.'
            : '`$label.$key` is not a flow entry key. Known keys: '
                  '${(<String>{..._kFlowCommonEntryKeys, ...ownKeys}.toList()..sort()).join(', ')}.',
      ),
    );
  }

  // argv keys: refused outright with the gate closed.
  final argvKeys = <String>[
    'handoff',
    if (kind == FlowKind.nextpnr) ...['fusesoc', 'extra_args'],
  ];
  if (!allowTooling) {
    for (final key in argvKeys) {
      if (node[key] == null) continue;
      errors.add(
        _error(
          path: filePath,
          node: node.nodes[key],
          message:
              '`$label.$key` is part of a command line SimCrux spawns, which '
              'a project file may not choose on its own. $kProjectToolingRemedy',
        ),
      );
    }
  }

  final handoff = _readFlowHandoff(node, label, filePath, errors);

  if (kind == null || name == null) return null;
  final gate = _ProjectExecutableGate(allowTooling: allowTooling);

  FlowEntry? entry;
  switch (kind) {
    case FlowKind.librelane:
      entry = _readLibrelaneEntry(
        node,
        name,
        label,
        shownLabel,
        filePath,
        errors,
        gate,
        handoff,
      );
    case FlowKind.nextpnr:
      entry = _readNextpnrEntry(
        node,
        name,
        label,
        shownLabel,
        filePath,
        errors,
        gate,
        handoff,
        allowTooling: allowTooling,
      );
  }
  if (gate.dropped.isNotEmpty) {
    final keys = gate.dropped.map((d) => '`${d.key}`').join(', ');
    errors.add(
      _error(
        path: filePath,
        node: gate.dropped.first.node,
        severity: ConfigLoaderErrorSeverity.warning,
        message:
            'Ignored $keys: a project file may not choose which program '
            'SimCrux runs. The Settings choice, or the conventional executable '
            'on PATH, is used instead. $kProjectToolingRemedy',
      ),
    );
  }
  final fatal = errors.skip(errorCount).any((e) => e.isFatal);
  return fatal ? null : entry;
}

FlowEntry? _readLibrelaneEntry(
  YamlMap node,
  String name,
  String label,
  String shownLabel,
  String filePath,
  List<ConfigLoaderError> errors,
  _ProjectExecutableGate gate,
  Map<String, List<String>> handoff,
) {
  final config = _readFlowPath(node, 'config', label, filePath, errors);
  if (config == null && node['config'] == null) {
    errors.add(
      _error(
        path: filePath,
        node: node,
        message:
            '$shownLabel needs `config`, the LibreLane design configuration '
            'file.',
      ),
    );
  }
  FlowLauncher? launcher;
  final launcherRaw = node['launcher'];
  if (launcherRaw != null) {
    launcher = FlowLauncher.fromWireName(launcherRaw);
    if (launcher == null) {
      errors.add(
        _error(
          path: filePath,
          node: node.nodes['launcher'],
          message:
              '`$label.launcher` must be path, nix or docker (got '
              '"$launcherRaw").',
        ),
      );
    } else if (!gate.allowTooling) {
      gate.dropped.add((key: '$label.launcher', node: node.nodes['launcher']));
      launcher = null;
    }
  }
  final pdk = _readFlowSafeName(node, 'pdk', label, filePath, errors);
  final tagPrefix =
      _readFlowSafeName(node, 'tag_prefix', label, filePath, errors) ??
      FlowEntry.kDefaultTagPrefix;
  return FlowEntry(
    name: name,
    kind: FlowKind.librelane,
    config: config,
    launcher: launcher,
    librelaneBinary: gate.read(
      node,
      'librelane_binary',
      label,
      filePath,
      errors,
    ),
    dockerImage: gate.read(node, 'docker_image', label, filePath, errors),
    pdk: pdk,
    tagPrefix: tagPrefix,
    gls: _readFlowGls(node, label, filePath, errors),
    equiv: _readFlowEquiv(node, label, filePath, errors),
    handoff: handoff,
  );
}

FlowEntry? _readNextpnrEntry(
  YamlMap node,
  String name,
  String label,
  String shownLabel,
  String filePath,
  List<ConfigLoaderError> errors,
  _ProjectExecutableGate gate,
  Map<String, List<String>> handoff, {
  required bool allowTooling,
}) {
  final fusesocNode = node['fusesoc'];
  if (fusesocNode != null) {
    for (final key in _kFlowNextpnrBuildKeys) {
      if (node[key] == null) continue;
      errors.add(
        _error(
          path: filePath,
          node: node.nodes[key],
          message:
              '`$label.$key` does not apply with `fusesoc`: FuseSoC builds '
              'the core with its own options.',
        ),
      );
    }
    final fusesoc = _readFlowFusesoc(node, label, filePath, errors, gate);
    if (fusesoc == null) return null;
    return FlowEntry(
      name: name,
      kind: FlowKind.nextpnr,
      fusesoc: fusesoc,
      handoff: handoff,
    );
  }

  final familyRaw = node['family'];
  final family = NextpnrFamily.fromWireName(familyRaw);
  if (familyRaw == null) {
    errors.add(
      _error(
        path: filePath,
        node: node,
        message:
            '$shownLabel needs `family`: '
            '${NextpnrFamily.values.map((f) => f.wireName).join(', ')}.',
      ),
    );
  } else if (family == null) {
    errors.add(
      _error(
        path: filePath,
        node: node.nodes['family'],
        message:
            '`$label.family` must be one of '
            '${NextpnrFamily.values.map((f) => f.wireName).join(', ')} (got '
            '"$familyRaw").',
      ),
    );
  }
  final device = _readFlowToken(node, 'device', label, filePath, errors);
  if (device == null && node['device'] == null) {
    errors.add(
      _error(
        path: filePath,
        node: node,
        message: '$shownLabel needs `device`.',
      ),
    );
  }
  final package = _readFlowToken(node, 'package', label, filePath, errors);
  if (package == null &&
      node['package'] == null &&
      (family == NextpnrFamily.ice40 || family == NextpnrFamily.ecp5)) {
    errors.add(
      _error(
        path: filePath,
        node: node,
        message: '$shownLabel needs `package` for ${family!.wireName}.',
      ),
    );
  }
  final top = _readRiscvString(node, 'top', label, filePath, errors);
  if (top == null && node['top'] == null) {
    errors.add(
      _error(path: filePath, node: node, message: '$shownLabel needs `top`.'),
    );
  } else if (top != null && !_kFlowIdentifier.hasMatch(top)) {
    errors.add(
      _error(
        path: filePath,
        node: node.nodes['top'],
        message: '`$label.top` must be an HDL identifier (got "$top").',
      ),
    );
  }
  final sources = <String>[];
  final sourcesNode = node.nodes['sources'];
  if (sourcesNode == null) {
    errors.add(
      _error(
        path: filePath,
        node: node,
        message: '$shownLabel needs `sources`, the RTL files to synthesise.',
      ),
    );
  } else if (sourcesNode is! YamlList || sourcesNode.isEmpty) {
    errors.add(
      _error(
        path: filePath,
        node: sourcesNode,
        message: '`$label.sources` must be a non-empty list of files.',
      ),
    );
  } else {
    for (final item in sourcesNode.nodes) {
      final value = item.value;
      final problem = value is String ? _flowPathProblem(value) : 'not a path';
      if (problem == null) {
        sources.add(value as String);
      } else {
        errors.add(
          _error(
            path: filePath,
            node: item,
            message: '`$label.sources` entry "$value": $problem.',
          ),
        );
      }
    }
  }
  final constraints = _readFlowPath(
    node,
    'constraints',
    label,
    filePath,
    errors,
  );
  double? freq;
  final freqRaw = node['freq_mhz'];
  if (freqRaw != null) {
    if (freqRaw is num && freqRaw.isFinite && freqRaw > 0 && freqRaw < 1e6) {
      freq = freqRaw.toDouble();
    } else {
      errors.add(
        _error(
          path: filePath,
          node: node.nodes['freq_mhz'],
          message: '`$label.freq_mhz` must be a positive number of MHz.',
        ),
      );
    }
  }
  final detailed = node['detailed_timing'];
  if (detailed != null && detailed is! bool) {
    errors.add(
      _error(
        path: filePath,
        node: node.nodes['detailed_timing'],
        message: '`$label.detailed_timing` must be true or false.',
      ),
    );
  }
  final extraArgs = allowTooling
      ? _readRiscvStringList(node, 'extra_args', label, filePath, errors) ??
            const <String>[]
      : const <String>[];
  if (family == null) return null;
  return FlowEntry(
    name: name,
    kind: FlowKind.nextpnr,
    family: family,
    device: device,
    package: package,
    constraints: constraints,
    top: top,
    sources: sources,
    freqMhz: freq,
    detailedTiming: detailed == true,
    extraArgs: extraArgs,
    handoff: handoff,
  );
}

FlowFusesocConfig? _readFlowFusesoc(
  YamlMap parent,
  String label,
  String filePath,
  List<ConfigLoaderError> errors,
  _ProjectExecutableGate gate,
) {
  final node = _riscvSubMap(parent, 'fusesoc', label, filePath, errors);
  if (node == null) return null;
  final sub = '$label.fusesoc';
  _rejectUnknownKeys(node, _kFlowFusesocKeys, sub, filePath, errors);
  final core = _readFlowToken(node, 'core', sub, filePath, errors);
  final target = _readFlowToken(node, 'target', sub, filePath, errors);
  for (final (key, value) in <(String, String?)>[
    ('core', core),
    ('target', target),
  ]) {
    if (value == null && node[key] == null) {
      errors.add(
        _error(
          path: filePath,
          node: node,
          message: '`$sub.$key` is required.',
        ),
      );
    }
  }
  final binary = gate.read(node, 'binary', sub, filePath, errors);
  if (core == null || target == null) return null;
  return FlowFusesocConfig(core: core, target: target, binary: binary);
}

FlowGlsConfig? _readFlowGls(
  YamlMap parent,
  String label,
  String filePath,
  List<ConfigLoaderError> errors,
) {
  final node = _riscvSubMap(parent, 'gls', label, filePath, errors);
  if (node == null) return null;
  final sub = '$label.gls';
  _rejectUnknownKeys(node, _kFlowGlsKeys, sub, filePath, errors);
  final tests =
      _readRiscvStringList(node, 'tests', sub, filePath, errors) ??
      const <String>[];
  final netlist = node['netlist'] ?? 'nl';
  if (!FlowGlsConfig.kNetlists.contains(netlist)) {
    errors.add(
      _error(
        path: filePath,
        node: node.nodes['netlist'],
        message: '`$sub.netlist` must be nl or pnl (got "$netlist").',
      ),
    );
  }
  final strictX = node['strict_x'];
  if (strictX != null && strictX is! bool) {
    errors.add(
      _error(
        path: filePath,
        node: node.nodes['strict_x'],
        message: '`$sub.strict_x` must be true or false.',
      ),
    );
  }
  final clock = _readRiscvString(node, 'clock', sub, filePath, errors);
  return FlowGlsConfig(
    tests: tests,
    netlist: netlist is String ? netlist : 'nl',
    strictX: strictX == true,
    clock: clock,
  );
}

FlowEquivConfig? _readFlowEquiv(
  YamlMap parent,
  String label,
  String filePath,
  List<ConfigLoaderError> errors,
) {
  final node = _riscvSubMap(parent, 'equiv', label, filePath, errors);
  if (node == null) return null;
  final sub = '$label.equiv';
  _rejectUnknownKeys(node, _kFlowEquivKeys, sub, filePath, errors);
  int? timeout;
  final timeoutRaw = node['partition_timeout_s'];
  if (timeoutRaw != null) {
    if (timeoutRaw is int && timeoutRaw > 0) {
      timeout = timeoutRaw;
    } else {
      errors.add(
        _error(
          path: filePath,
          node: node.nodes['partition_timeout_s'],
          message: '`$sub.partition_timeout_s` must be a positive integer.',
        ),
      );
    }
  }
  return FlowEquivConfig(
    partitionTimeoutS: timeout,
    acceptBlackbox:
        _readRiscvStringList(node, 'accept_blackbox', sub, filePath, errors) ??
        const <String>[],
  );
}

Map<String, List<String>> _readFlowHandoff(
  YamlMap parent,
  String label,
  String filePath,
  List<ConfigLoaderError> errors,
) {
  final node = _riscvSubMap(parent, 'handoff', label, filePath, errors);
  if (node == null) return const <String, List<String>>{};
  final sub = '$label.handoff';
  final out = <String, List<String>>{};
  for (final keyNode in node.nodes.keys) {
    final key = keyNode is YamlNode ? keyNode.value : keyNode;
    if (key is! String || !FlowEntry.kHandoffViewers.contains(key)) {
      errors.add(
        _error(
          path: filePath,
          node: keyNode is YamlNode ? keyNode : node,
          message:
              '`$sub.$key` is not a hand-off viewer. Known viewers: '
              '${FlowEntry.kHandoffViewers.join(', ')}.',
        ),
      );
      continue;
    }
    final argv = _readRiscvStringList(node, key, sub, filePath, errors);
    if (argv == null || argv.isEmpty) {
      errors.add(
        _error(
          path: filePath,
          node: node.nodes[key],
          message: '`$sub.$key` must be a non-empty command list.',
        ),
      );
      continue;
    }
    out[key] = argv;
  }
  return out;
}

void _rejectUnknownKeys(
  YamlMap node,
  Set<String> known,
  String label,
  String filePath,
  List<ConfigLoaderError> errors,
) {
  for (final keyNode in node.nodes.keys) {
    final key = keyNode is YamlNode ? keyNode.value : keyNode;
    if (key is String && known.contains(key)) continue;
    errors.add(
      _error(
        path: filePath,
        node: keyNode is YamlNode ? keyNode : node,
        message:
            '`$label.$key` is not a known key. Known keys: '
            '${(known.toList()..sort()).join(', ')}.',
      ),
    );
  }
}

/// A name that must be one safe segment ([_kFlowSafeName]).
String? _readFlowSafeName(
  YamlMap node,
  String key,
  String label,
  String filePath,
  List<ConfigLoaderError> errors,
) {
  final value = _readRiscvString(node, key, label, filePath, errors);
  if (value == null) return null;
  if (_kFlowSafeName.hasMatch(value) &&
      FormalContainment.segmentProblem(value) == null) {
    return value;
  }
  errors.add(
    _error(
      path: filePath,
      node: node.nodes[key],
      message:
          '`$label.$key` "$value" must be letters, digits, `_`, `.` and `-` '
          '(at most 64), because it names a directory and a test.',
    ),
  );
  return null;
}

/// A single command-line token: a device, a package, a core or a target.
/// It may not start with `-`, so it can never be read as an option.
String? _readFlowToken(
  YamlMap node,
  String key,
  String label,
  String filePath,
  List<ConfigLoaderError> errors,
) {
  final raw = node[key];
  final value = raw is num ? raw.toString() : raw;
  if (value == null) return null;
  if (value is String &&
      value.isNotEmpty &&
      !value.startsWith('-') &&
      !value.contains(RegExp(r'[\s\x00]'))) {
    return value;
  }
  errors.add(
    _error(
      path: filePath,
      node: node.nodes[key],
      message:
          '`$label.$key` must be one word that does not start with `-` (got '
          '"$value").',
    ),
  );
  return null;
}

/// A project path (`config`, `constraints`).
String? _readFlowPath(
  YamlMap node,
  String key,
  String label,
  String filePath,
  List<ConfigLoaderError> errors,
) {
  final value = _readRiscvString(node, key, label, filePath, errors);
  if (value == null) return null;
  final problem = _flowPathProblem(value);
  if (problem == null) return value;
  errors.add(
    _error(
      path: filePath,
      node: node.nodes[key],
      message: '`$label.$key` "$value": $problem.',
    ),
  );
  return null;
}

/// Why [value] cannot be a project path, or null. The run-time check
/// resolves symlinks against the project root; this one refuses what no
/// project could mean.
String? _flowPathProblem(String value) {
  if (value.trim().isEmpty) return 'it is empty';
  if (value.contains('\x00')) return 'it contains a NUL byte';
  if (value.contains('\n') || value.contains('\r')) {
    return 'it contains a line break';
  }
  if (value.startsWith('-')) return 'it starts with `-`';
  return null;
}
