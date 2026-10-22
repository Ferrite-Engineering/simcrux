// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

/// The direction of a netlist port.
enum GlsPortDirection {
  /// `input`.
  input,

  /// `output`.
  output,

  /// `inout`.
  inout,
}

/// One top-level port of a netlist.
@immutable
class GlsPort {
  /// Creates a port.
  const GlsPort(this.name, this.direction);

  /// The port's name as the netlist writes it.
  final String name;

  /// Its direction.
  final GlsPortDirection direction;

  /// Whether the name is a plain identifier a hierarchical reference can
  /// use. A Yosys `splitnets -ports` netlist names its bits `\a[0] `, which
  /// the RTL testbench's `.a(a)` cannot bind.
  bool get usable => _identifier.hasMatch(name);

  static final RegExp _identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_$]*$');
}

/// The top module's ports, read from a gate-level netlist.
@immutable
class GlsNetlistPorts {
  /// Creates the port list.
  const GlsNetlistPorts(this.ports);

  /// The ports, in declaration order.
  final List<GlsPort> ports;

  /// The inputs.
  Iterable<GlsPort> get inputs =>
      ports.where((p) => p.direction == GlsPortDirection.input);

  /// Whether every port can be referred to by name.
  bool get allUsable => ports.isNotEmpty && ports.every((p) => p.usable);

  /// The supply ports a power-aware netlist adds.
  static const Set<String> kSupplyPorts = <String>{
    'VPWR',
    'VGND',
    'VPB',
    'VNB',
    'VDD',
    'VSS',
    'vccd1',
    'vssd1',
  };

  /// The ports a testbench drives or reads: everything but the supply.
  List<GlsPort> get signalPorts => <GlsPort>[
    for (final p in ports)
      if (!kSupplyPorts.contains(p.name)) p,
  ];

  /// The input ports whose names read as a clock.
  List<String> get clockCandidates => <String>[
    for (final p in inputs)
      if (_clockName.hasMatch(p.name)) p.name,
  ];

  static final RegExp _clockName = RegExp(
    r'(^|_)(clk|clock|ck)(_|\d|$)',
    caseSensitive: false,
  );

  /// Reads the ports of module [top] from the netlist at [path].
  ///
  /// A bounded stream: the netlist is read line by line to the module's
  /// `endmodule`, and only the lines that declare a port are kept, so a
  /// hundred-megabyte netlist is never held in memory. Returns null when
  /// [top] is not in the file. Throws [FileSystemException] when the file
  /// cannot be read.
  static Future<GlsNetlistPorts?> read(
    String path,
    String top, {
    int maxBytes = 1024 * 1024 * 1024,
  }) async {
    final file = File(path);
    if (await file.length() > maxBytes) return null;
    final ports = <GlsPort>[];
    var inside = false;
    var found = false;
    final module = RegExp(r'^\s*module\s+(\\?[^\s(;]+)');
    await for (final line
        in file
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (!inside) {
        final m = module.firstMatch(line);
        if (m != null && m.group(1) == top) {
          inside = true;
          found = true;
        }
        continue;
      }
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('endmodule')) break;
      final direction = trimmed.startsWith('input ')
          ? GlsPortDirection.input
          : trimmed.startsWith('output ')
          ? GlsPortDirection.output
          : trimmed.startsWith('inout ')
          ? GlsPortDirection.inout
          : null;
      if (direction == null) continue;
      final semi = trimmed.indexOf(';');
      if (semi < 0) continue;
      var rest = trimmed.substring(trimmed.indexOf(' ') + 1, semi).trim();
      rest = rest.replaceFirst(RegExp(r'^(wire|reg|logic)\s+'), '');
      rest = rest.replaceFirst(RegExp(r'^\[[^\]]*\]\s*'), '');
      for (final name in rest.split(',')) {
        final n = name.trim();
        if (n.isNotEmpty) ports.add(GlsPort(n, direction));
      }
    }
    return found ? GlsNetlistPorts(ports) : null;
  }
}

/// Where the testbench instantiates the design: a hierarchical path from the
/// testbench top to the instance, found without elaborating anything.
@immutable
class GlsDutScope {
  /// Creates a scope.
  const GlsDutScope(this.path);

  /// The dotted path (`tb.uut`), beginning with the testbench top.
  final String path;

  /// The instance's name (`uut`).
  String get instance => path.substring(path.lastIndexOf('.') + 1);

  /// Why no scope was found.
  static const String ambiguous = 'ambiguous';

  /// Finds the instance of [design] under [testbenchTop], reading [sources]
  /// (the testbench's files: the design's own sources are not among them).
  ///
  /// A breadth-first walk over the module definitions the sources hold,
  /// following instantiations of those modules only, to a depth of eight.
  /// Returns null when there is no instance and [ambiguous] through
  /// [GlsDutScopeResult.problem] when there is more than one.
  static GlsDutScopeResult find({
    required List<String> sources,
    required String testbenchTop,
    required String design,
  }) {
    final modules = <String, String>{};
    for (final path in sources) {
      final String text;
      try {
        final file = File(path);
        if (file.lengthSync() > 8 * 1024 * 1024) continue;
        text = file.readAsStringSync();
      } on FileSystemException {
        continue;
      }
      _collectModules(_stripComments(text), modules);
    }
    final root = modules[testbenchTop];
    if (root == null) {
      return const GlsDutScopeResult(problem: 'testbench_not_found');
    }
    final hits = <String>[];
    final queue = <(String module, String path, int depth)>[
      (testbenchTop, testbenchTop, 0),
    ];
    final seen = <String>{};
    while (queue.isNotEmpty) {
      final (module, path, depth) = queue.removeAt(0);
      final body = modules[module];
      if (body == null || depth > 8) continue;
      for (final inst in _instances(body)) {
        if (inst.module == design) {
          hits.add('$path.${inst.name}');
        } else if (modules.containsKey(inst.module) &&
            seen.add('$path.${inst.name}')) {
          queue.add((inst.module, '$path.${inst.name}', depth + 1));
        }
      }
    }
    if (hits.isEmpty) return const GlsDutScopeResult(problem: 'not_found');
    if (hits.length > 1) return const GlsDutScopeResult(problem: ambiguous);
    return GlsDutScopeResult(scope: GlsDutScope(hits.single));
  }

  static String _stripComments(String text) => text
      .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), ' ')
      .replaceAll(RegExp(r'//[^\n]*'), ' ');

  static void _collectModules(String text, Map<String, String> out) {
    final header = RegExp(r'\bmodule\s+(\w+)');
    for (final m in header.allMatches(text)) {
      final end = text.indexOf('endmodule', m.end);
      if (end < 0) continue;
      out.putIfAbsent(m.group(1)!, () => text.substring(m.end, end));
    }
  }

  static const Set<String> _keywords = <String>{
    'module',
    'input',
    'output',
    'inout',
    'wire',
    'reg',
    'logic',
    'assign',
    'always',
    'initial',
    'begin',
    'end',
    'if',
    'else',
    'for',
    'while',
    'case',
    'function',
    'task',
    'integer',
    'parameter',
    'localparam',
    'genvar',
    'generate',
    'endgenerate',
    'real',
    'time',
    'realtime',
    'forever',
    'repeat',
    'wait',
    'fork',
    'join',
    'return',
    'automatic',
    'int',
    'bit',
    'byte',
    'string',
    'typedef',
    'import',
    'defparam',
  };

  static Iterable<({String module, String name})> _instances(
    String body,
  ) sync* {
    // `<module> [#( ... )] <name> (` at the start of a statement.
    final inst = RegExp(
      r'(?:^|[;\s])(\\?\w+)\s*(?:#\s*\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\))?\s+(\w+)\s*(?:\[[^\]]*\]\s*)?\(',
    );
    for (final m in inst.allMatches(body)) {
      final module = m.group(1)!;
      if (_keywords.contains(module)) continue;
      yield (module: module, name: m.group(2)!);
    }
  }
}

/// A [GlsDutScope], or why there is none.
@immutable
class GlsDutScopeResult {
  /// Creates a result.
  const GlsDutScopeResult({this.scope, this.problem});

  /// The scope, when found.
  final GlsDutScope? scope;

  /// `testbench_not_found`, `not_found` or [GlsDutScope.ambiguous].
  final String? problem;
}
