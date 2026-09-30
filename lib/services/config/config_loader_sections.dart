// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

part of 'config_loader.dart';

// Remaining structured-section parsers: `output:`, `waveform:`,
// `simulators:`, and `resources:`. Each is a self-contained reader over
// its subtree that appends structured errors and returns a typed model.

/// Reads the optional `output:` block.
///
/// `results_path` and `summary_path` name files a `--ci` run creates and
/// truncates, so each must stay inside the directory holding the project
/// file: `../`, an absolute path elsewhere, or a symbolic link that leads
/// out is refused here, at the value's line and column. Only
/// [allowTooling] (`--allow-project-tooling`, or the Settings switch that
/// means the same) lets a project file write elsewhere. See
/// `project_output_path.dart` for the rule, which the writer applies again
/// before it opens either file.
OutputConfig _readOutputConfig(
  YamlMap root,
  String path,
  List<ConfigLoaderError> errors, {
  required bool allowTooling,
}) {
  final node = root['output'];
  if (node == null) return const OutputConfig();
  if (node is! YamlMap) {
    errors.add(
      _error(
        path: path,
        node: root.nodes['output'],
        message: '`output` must be a map.',
      ),
    );
    return const OutputConfig();
  }
  final streamingRaw = node['streaming'];
  var streaming = false;
  if (streamingRaw is bool) {
    streaming = streamingRaw;
  } else if (streamingRaw != null) {
    errors.add(
      _error(
        path: path,
        node: node.nodes['streaming'],
        message: '`output.streaming` must be a boolean.',
      ),
    );
  }
  return OutputConfig(
    streaming: streaming,
    streamingResultsPath: _readOutputPath(
      node,
      'results_path',
      path,
      errors,
      allowTooling: allowTooling,
    ),
    streamingSummaryPath: _readOutputPath(
      node,
      'summary_path',
      path,
      errors,
      allowTooling: allowTooling,
    ),
  );
}

/// Reads `output.<key>`, refusing a value that is not a string or, unless
/// [allowTooling], one that leads outside the project directory.
String? _readOutputPath(
  YamlMap node,
  String key,
  String path,
  List<ConfigLoaderError> errors, {
  required bool allowTooling,
}) {
  final valueNode = node.nodes[key];
  if (valueNode == null || valueNode.value == null) return null;
  final value = valueNode.value;
  if (value is! String) {
    errors.add(
      _error(
        path: path,
        node: valueNode,
        message: '`output.$key` must be a path string.',
      ),
    );
    return null;
  }
  if (allowTooling) return value;
  final projectDir = p.dirname(path);
  final problem = projectOutputPathProblem(value, projectDir);
  if (problem == null) return value;
  errors.add(
    _error(
      path: path,
      node: valueNode,
      message:
          '`output.$key` must stay inside the project directory (got '
          '"${value.replaceAll('\u0000', r'\0')}": $problem). A `--ci` run '
          'creates and truncates this file, so a path outside the project '
          'would overwrite a file SimCrux did not create. Use a path under '
          '$projectDir, such as `build/results.ndjson`. '
          '$kProjectToolingRemedy',
    ),
  );
  return null;
}

/// Reads the optional `simulators:` block.
///
/// `path:` and `env:` are **project-defined tooling**: a `simcrux.yaml`
/// that sets them chooses which binary the app spawns and what
/// environment it spawns under, and both are code execution on the
/// machine that opens the file. `path: /tmp/pwn` is the direct form;
/// `env: {LD_PRELOAD: ./pwn.so}` (or `DYLD_INSERT_LIBRARIES`,
/// `PYTHONPATH`, `PATH`, …) is the same thing against a legitimate
/// simulator, which is why there is no safe subset of `env` to allow.
///
/// A project file is untrusted input — `.yaml` and `.yml` are
/// registered SimCrux document types (`macos/Runner/Info.plist`), so
/// one arrives by double-click, by clone, or by download. So the
/// values are honored only when [allowTooling] says a human made that
/// decision: the [kAllowProjectToolingControlLabel] switch in
/// Settings → Simulators (default off), or `--allow-project-tooling` on
/// the CLI, which has no Settings to read. Otherwise they are dropped and the
/// entry degrades to `source: system` with a load advisory naming the
/// keys, the file, and where to turn it on.
Map<String, SimulatorBinaryConfig> _readSimulatorBinaries(
  YamlMap root,
  String path,
  List<ConfigLoaderError> errors, {
  required bool allowTooling,
}) {
  final node = root.nodes['simulators'];
  if (node == null) return const <String, SimulatorBinaryConfig>{};
  if (node is! YamlMap) {
    errors.add(
      _error(
        path: path,
        node: node,
        message: '`simulators` must be a map of simulator id to config.',
      ),
    );
    return const <String, SimulatorBinaryConfig>{};
  }
  final out = <String, SimulatorBinaryConfig>{};
  for (final entry in node.nodes.entries) {
    final keyNode = entry.key as YamlNode;
    final valueNode = entry.value;
    final simulatorId = (keyNode.value ?? '').toString();
    if (simulatorId.isEmpty) {
      errors.add(
        _error(
          path: path,
          node: keyNode,
          message: 'Simulator id must be a non-empty string.',
        ),
      );
      continue;
    }
    if (valueNode is! YamlMap) {
      errors.add(
        _error(
          path: path,
          node: valueNode,
          message: 'Simulator `$simulatorId` config must be a map.',
        ),
      );
      continue;
    }
    final sourceStr = _readString(valueNode, ['source']);
    // Omitting `source:` means `$PATH`, not "the bundled copy" — nothing
    // is bundled today, and the old `bundled` default made a
    // simulator-not-installed failure report itself as a broken bundled
    // binary. An explicit `source: bundled` is still honored.
    var source = SimulatorBinarySource.system;
    switch (sourceStr) {
      case null:
        source = SimulatorBinarySource.system;
      case 'bundled':
        source = SimulatorBinarySource.bundled;
      case 'system':
        source = SimulatorBinarySource.system;
      case 'custom':
        source = SimulatorBinarySource.custom;
      default:
        errors.add(
          _error(
            path: path,
            node: valueNode.nodes['source'],
            message:
                'Simulator `$simulatorId` has unknown source "$sourceStr" '
                '(expected bundled / system / custom).',
          ),
        );
    }
    var customPath = _readString(valueNode, ['path']);
    var extraEnv =
        _readStringMap(valueNode, ['env'], path, errors) ??
        const <String, String>{};
    // The trust gate. Parse the keys either way so a malformed `env:`
    // still reports as malformed, then drop the values unless a human
    // opted in. See this function's doc for why `env` is gated whole.
    var toolingDropped = false;
    if (!allowTooling && (customPath != null || extraEnv.isNotEmpty)) {
      final gated = <String>[
        if (customPath != null) '`path`',
        if (extraEnv.isNotEmpty) '`env`',
      ];
      errors.add(
        _error(
          path: path,
          node: valueNode.nodes['path'] ?? valueNode.nodes['env'] ?? valueNode,
          severity: ConfigLoaderErrorSeverity.warning,
          message:
              'Ignored ${gated.join(' and ')} on simulator `$simulatorId`: a '
              'project file may not choose which binary SimCrux runs or what '
              'environment it runs under. Falling back to source=system; set '
              'a binary for this machine in $kSettingsSimulatorsRoute → '
              '"$kSimulatorBinaryPathControlLabel". $kProjectToolingRemedy',
        ),
      );
      customPath = null;
      extraEnv = const <String, String>{};
      toolingDropped = true;
      // `custom` without a path resolves to the bare binary name anyway;
      // say so in the model rather than leaving a lying `source`, and
      // so the Settings → Simulators override still applies (the runner
      // skips simulators the project declared `custom`).
      if (source == SimulatorBinarySource.custom) {
        source = SimulatorBinarySource.system;
      }
    }
    final options =
        _readStringMap(valueNode, ['options'], path, errors) ??
        const <String, String>{};
    if (simulatorId == 'cocotb' &&
        !_isCocotbMaxFailures(options['max_failures'])) {
      errors.add(
        _error(
          path: path,
          node:
              (valueNode.nodes['options'] as YamlMap?)?.nodes['max_failures'] ??
              valueNode.nodes['options'],
          message: _cocotbMaxFailuresMessage(
            'simulators.cocotb.options.max_failures',
            options['max_failures']!,
          ),
        ),
      );
    }
    // Not `else if` on [toolingDropped] alone: a gated entry has already
    // been downgraded to `system`, so this only fires for an entry that
    // genuinely never named a path.
    if (!toolingDropped &&
        source == SimulatorBinarySource.custom &&
        customPath == null) {
      errors.add(
        _error(
          path: path,
          node: valueNode,
          message:
              'Simulator `$simulatorId` source=custom requires a `path` field.',
        ),
      );
    }
    out[simulatorId] = SimulatorBinaryConfig(
      simulatorId: simulatorId,
      source: source,
      customPath: customPath,
      extraEnv: extraEnv,
      options: options,
    );
  }
  return out;
}

WaveformPolicy? _readWaveformPolicy(
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
        message: '`${path.join('.')}` must be a map.',
      ),
    );
    return null;
  }
  var capture = WaveformCapturePolicy.onFailure;
  var format = WaveformFormat.fst;
  final captureStr = node['capture'];
  switch (captureStr) {
    case null:
      break;
    case 'always':
      capture = WaveformCapturePolicy.always;
    case 'on_failure':
      capture = WaveformCapturePolicy.onFailure;
    case 'on_demand':
      capture = WaveformCapturePolicy.onDemand;
    case 'never':
      capture = WaveformCapturePolicy.never;
    default:
      errors.add(
        _error(
          path: filePath,
          node: node.nodes['capture'],
          message:
              'Field `${path.join('.')}.capture`: unknown value "$captureStr" '
              '(expected always / on_failure / on_demand / never).',
        ),
      );
  }
  final formatStr = node['format'];
  switch (formatStr) {
    case null:
      break;
    case 'vcd':
      format = WaveformFormat.vcd;
    case 'fst':
      format = WaveformFormat.fst;
    case 'ghw':
      format = WaveformFormat.ghw;
    default:
      errors.add(
        _error(
          path: filePath,
          node: node.nodes['format'],
          message:
              'Field `${path.join('.')}.format`: unknown value "$formatStr" '
              '(expected vcd / fst / ghw).',
        ),
      );
  }
  return WaveformPolicy(capture: capture, format: format);
}

List<ResourceLock>? _readResourceLocks(
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
        message: '`${path.join('.')}` must be a list of resource names.',
      ),
    );
    return null;
  }
  final out = <ResourceLock>[];
  for (final entry in node) {
    if (entry is String && entry.isNotEmpty) {
      out.add(ResourceLock(name: entry));
    } else {
      errors.add(
        _error(
          path: filePath,
          node: currentNode,
          message:
              'Entries in `${path.join('.')}` must be non-empty strings '
              '(named resource locks).',
        ),
      );
    }
  }
  return out;
}

/// Whether [raw] is an acceptable cocotb `max_failures`: absent, empty, or a
/// positive integer.
///
/// Checked at load, with the file and line, because the driver can only
/// reject a bad value once the test is already dispatched.
bool _isCocotbMaxFailures(String? raw) {
  if (raw == null || raw.isEmpty) return true;
  final parsed = int.tryParse(raw);
  return parsed != null && parsed >= 1;
}

String _cocotbMaxFailuresMessage(String field, String raw) =>
    '`$field` must be a positive integer (got "$raw").';
