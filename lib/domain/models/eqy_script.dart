// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

/// One `[strategy <name>]` section of an `.eqy` file.
@immutable
class EqyStrategy {
  /// Creates a strategy.
  const EqyStrategy({
    required this.name,
    this.type,
    this.engine,
    this.depth,
    this.timeoutSeconds,
  });

  /// The section's name; EQY writes its work under
  /// `strategies/<partition>/<name>/`.
  final String name;

  /// The `use` line: `sby`, `sat`, `imctk` or `dummy`. Null when the section
  /// has none, which EQY refuses.
  final String? type;

  /// The `engine` line of an `sby` strategy (`smtbmc yices`), when set.
  final String? engine;

  /// The `depth` line, when set: the induction depth, not a bound.
  final int? depth;

  /// The `timeout` line in seconds, when set.
  final int? timeoutSeconds;

  /// The engine specification this strategy actually runs: its `engine`
  /// line, else EQY's default for the type (`smtbmc` for `sby`,
  /// `aiger imctk-eqy-engine` for `imctk`, Yosys's own `sat` for `sat`,
  /// nothing for `dummy`).
  String? get effectiveEngine => switch (type) {
    'sby' => engine ?? 'smtbmc',
    'imctk' => 'aiger imctk-eqy-engine',
    'sat' => 'sat',
    _ => null,
  };
}

/// One line of a pattern section (`[match <module>]`, `[collect …]`,
/// `[partition …]`), with the module pattern it applies to.
@immutable
class EqyPatternLine {
  /// Creates a line.
  const EqyPatternLine({required this.module, required this.text});

  /// The section's module pattern (`alu`, `*`).
  final String module;

  /// The line as written (`gold-nomatch r`).
  final String text;
}

/// The facts SimCrux reads out of an EQY `.eqy` file.
///
/// Pure and I/O-free (`domain/`), shared by the importer and the `eqy`
/// driver so they cannot read one file two ways. It follows EQY's own
/// reader: `#` comments, `[options]`, `[gold]`, `[gate]` and `[script]`
/// sections, the pattern sections `[recode <a> <b>]`, `[match <module>]`,
/// `[collect <module>]` and `[partition <module>]`, and named
/// `[strategy <name>]` sections. Unknown sections are kept by name only.
///
/// `eqy` remains the authority on what the file means; nothing here changes
/// how a check is run.
@immutable
class EqyScript {
  /// Creates an [EqyScript].
  const EqyScript({
    this.gold = const <String>[],
    this.gate = const <String>[],
    this.script = const <String>[],
    this.options = const <String>[],
    this.match = const <EqyPatternLine>[],
    this.collect = const <EqyPatternLine>[],
    this.partition = const <EqyPatternLine>[],
    this.strategies = const <EqyStrategy>[],
    this.sections = const <String>[],
  });

  /// Parses [text]. Never throws: an unusual file yields fewer facts.
  factory EqyScript.parse(String text) {
    final gold = <String>[];
    final gate = <String>[];
    final script = <String>[];
    final options = <String>[];
    final match = <EqyPatternLine>[];
    final collect = <EqyPatternLine>[];
    final partition = <EqyPatternLine>[];
    final strategyLines = <String, List<String>>{};
    final sections = <String>[];
    var section = '';
    String? argument;
    for (final raw in text.split('\n')) {
      final hash = raw.indexOf('#');
      final line = (hash < 0 ? raw : raw.substring(0, hash)).trim();
      if (line.isEmpty) continue;
      if (line.startsWith('[') && line.endsWith(']')) {
        final words = line
            .substring(1, line.length - 1)
            .trim()
            .split(RegExp(r'\s+'));
        section = words.first;
        argument = words.length > 1 ? words.sublist(1).join(' ') : null;
        sections.add(section);
        if (section == 'strategy' && argument != null) {
          strategyLines.putIfAbsent(argument, () => <String>[]);
        }
        continue;
      }
      switch (section) {
        case 'gold':
          gold.add(line);
        case 'gate':
          gate.add(line);
        case 'script':
          script.add(line);
        case 'options':
          options.add(line);
        case 'match':
          match.add(EqyPatternLine(module: argument ?? '*', text: line));
        case 'collect':
          collect.add(EqyPatternLine(module: argument ?? '*', text: line));
        case 'partition':
          partition.add(EqyPatternLine(module: argument ?? '*', text: line));
        case 'strategy':
          if (argument != null) strategyLines[argument]!.add(line);
      }
    }
    return EqyScript(
      gold: List<String>.unmodifiable(gold),
      gate: List<String>.unmodifiable(gate),
      script: List<String>.unmodifiable(script),
      options: List<String>.unmodifiable(options),
      match: List<EqyPatternLine>.unmodifiable(match),
      collect: List<EqyPatternLine>.unmodifiable(collect),
      partition: List<EqyPatternLine>.unmodifiable(partition),
      strategies: List<EqyStrategy>.unmodifiable(<EqyStrategy>[
        for (final MapEntry(:key, :value) in strategyLines.entries)
          _strategy(key, value),
      ]),
      sections: List<String>.unmodifiable(sections),
    );
  }

  static EqyStrategy _strategy(String name, List<String> lines) {
    String? type;
    String? engine;
    int? depth;
    int? timeout;
    for (final line in lines) {
      final words = line.split(RegExp(r'\s+'));
      if (words.length < 2) continue;
      switch (words.first) {
        case 'use':
          type ??= words[1];
        case 'engine':
          engine ??= words.sublist(1).join(' ');
        case 'depth':
          depth ??= int.tryParse(words[1]);
        case 'timeout':
          timeout ??= int.tryParse(words[1]);
      }
    }
    return EqyStrategy(
      name: name,
      type: type,
      engine: engine,
      depth: depth,
      timeoutSeconds: timeout,
    );
  }

  /// The `[gold]` Yosys script lines.
  final List<String> gold;

  /// The `[gate]` Yosys script lines.
  final List<String> gate;

  /// The `[script]` lines, run on both designs.
  final List<String> script;

  /// The `[options]` lines.
  final List<String> options;

  /// The `[match …]` lines.
  final List<EqyPatternLine> match;

  /// The `[collect …]` lines.
  final List<EqyPatternLine> collect;

  /// The `[partition …]` lines.
  final List<EqyPatternLine> partition;

  /// The `[strategy …]` sections, in the order the file declares them,
  /// which is the order EQY tries them on each partition.
  final List<EqyStrategy> strategies;

  /// Every section header seen, by its first word, in order.
  final List<String> sections;

  /// Whether the file has the two sections EQY requires.
  bool get hasGoldAndGate => gold.isNotEmpty && gate.isNotEmpty;

  /// The lines of `[gold]`, `[gate]` and `[script]` that call the GHDL Yosys
  /// plugin (`ghdl …`). SimCrux reads VHDL only after lowering it with a
  /// standalone `ghdl --synth --out=verilog`, never through the plugin, so a
  /// file that uses it is refused before anything runs.
  List<String> get vhdlPluginLines => <String>[
    for (final line in <String>[...gold, ...gate, ...script])
      if (_firstWord(line) == 'ghdl') line,
  ];

  /// The engine word for the whole file: the first word of every strategy's
  /// [EqyStrategy.effectiveEngine] when they agree (`smtbmc`, `aiger`,
  /// `sat`), `mixed` when they differ, null when no strategy names one.
  String? get engineWord {
    final words = <String>{
      for (final s in strategies)
        if (s.effectiveEngine case final String e) _firstWord(e),
    };
    if (words.isEmpty) return null;
    return words.length == 1 ? words.single : 'mixed';
  }

  /// The rest of the engine specification (`yices`) when exactly one
  /// strategy runs an engine and it names more than the engine word.
  String? get solver {
    final engines = <String>[
      for (final s in strategies)
        if (s.effectiveEngine case final String e) e,
    ];
    if (engines.length != 1) return null;
    final words = engines.single.split(RegExp(r'\s+'));
    return words.length > 1 ? words.skip(1).join(' ') : null;
  }

  static String _firstWord(String line) =>
      line.trim().split(RegExp(r'[\s;]+')).first;
}
