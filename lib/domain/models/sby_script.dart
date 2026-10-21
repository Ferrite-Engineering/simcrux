// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

/// The handful of facts SimCrux reads out of a `.sby` file.
///
/// Pure and I/O-free (`domain/`), and shared by construction between the
/// two callers that must not disagree: [RiscvFormalCheckImporter] reads
/// [tasks] to decide how many `TestSpec`s one file becomes, and
/// `RiscvFormalDriver` reads [proofMode] and [depth] at run time to
/// report what was configured. Reading it at run time rather than baking
/// it into the emitted YAML keeps the numbers honest when the user edits
/// the `.sby` afterwards — which, riscv-formal's `genchecks.py` being a
/// generator, they regularly do.
///
/// Deliberately not a general `.sby` parser. It reads the section
/// headers, the `[options]` key/value lines, the `[tasks]` names, the
/// `[engines]` lines, the `[script]` lines and the `[files]` entries, and
/// ignores everything else. `sby` itself remains the authority on what a
/// `.sby` file means; nothing here changes how a proof is run.
@immutable
class SbyScript {
  /// Creates an [SbyScript].
  const SbyScript({
    this.proofMode,
    this.depth,
    this.timeoutSeconds,
    this.tasks = const <String>[],
    this.files = const <String, String>{},
    this.taskGroups = const <String, List<String>>{},
    this.modeLines = const <SbyScopedLine>[],
    this.engineLines = const <SbyScopedLine>[],
    this.scriptLines = const <SbyScopedLine>[],
  });

  /// Parses [text]. Never throws: an unreadable or unusual file yields an
  /// all-null result, and the driver simply reports fewer metrics.
  factory SbyScript.parse(String text) {
    String? mode;
    int? depth;
    int? timeout;
    final tasks = <String>[];
    final files = <String, String>{};
    final taskGroups = <String, List<String>>{};
    final modeLines = <SbyScopedLine>[];
    final engineLines = <SbyScopedLine>[];
    final scriptLines = <SbyScopedLine>[];
    var section = '';
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (line.startsWith('[') && line.endsWith(']')) {
        section = line.substring(1, line.length - 1).trim().toLowerCase();
        continue;
      }
      if (section == 'options') {
        // Options may be task-scoped (`mytask: depth 30`); the leading
        // scope is stripped so the unscoped default is still read, and each
        // `mode` line is kept with its scope for [modeFor].
        final scoped = line.contains(':')
            ? line.substring(line.indexOf(':') + 1).trim()
            : line;
        final parts = scoped.split(RegExp(r'\s+'));
        if (parts.length < 2) continue;
        switch (parts.first) {
          case 'mode':
            mode ??= parts[1];
            modeLines.add(
              SbyScopedLine(scope: _taskScope(line), text: parts[1]),
            );
          case 'depth':
            depth ??= int.tryParse(parts[1]);
          case 'timeout':
            timeout ??= int.tryParse(parts[1]);
        }
      } else if (section == 'engines') {
        engineLines.add(
          SbyScopedLine(scope: _taskScope(line), text: _unscoped(line)),
        );
      } else if (section == 'script') {
        scriptLines.add(
          SbyScopedLine(scope: _taskScope(line), text: _unscoped(line)),
        );
      } else if (section == 'tasks') {
        // `<task> [<group> …]` — the first token names the task, the rest
        // are groups a scoped line may name instead of the task.
        final words = line.split(RegExp(r'\s+'));
        final name = words.first;
        if (name.isNotEmpty && !tasks.contains(name)) {
          tasks.add(name);
          taskGroups[name] = List<String>.unmodifiable(words.skip(1));
        }
      } else if (section == 'files') {
        // `<src>` copies to its basename; `<dest> <src>` names the copy.
        // Task-scoped entries (`task: <src>`) are read unscoped.
        final unscoped = RegExp(r'^[\w.~-]+:\s').hasMatch(line)
            ? line.substring(line.indexOf(':') + 1).trim()
            : line;
        final parts = unscoped.split(RegExp(r'\s+'));
        if (parts.length == 1) {
          final src = parts.first;
          final slash = src.replaceAll(r'\', '/').lastIndexOf('/');
          files.putIfAbsent(
            slash < 0 ? src : src.substring(slash + 1),
            () => src,
          );
        } else if (parts.length == 2) {
          files.putIfAbsent(parts.first, () => parts[1]);
        }
      }
    }
    return SbyScript(
      proofMode: mode,
      depth: depth,
      timeoutSeconds: timeout,
      tasks: List<String>.unmodifiable(tasks),
      files: Map<String, String>.unmodifiable(files),
      taskGroups: Map<String, List<String>>.unmodifiable(taskGroups),
      modeLines: List<SbyScopedLine>.unmodifiable(modeLines),
      engineLines: List<SbyScopedLine>.unmodifiable(engineLines),
      scriptLines: List<SbyScopedLine>.unmodifiable(scriptLines),
    );
  }

  /// `[tasks]`-scoped line prefix: `task:` or `task1 task2:` followed by
  /// whitespace.
  static final RegExp _scopePattern = RegExp(
    r'^([\w.~-]+(?:\s+[\w.~-]+)*):\s+(.*)$',
  );

  /// The task names a scoped line applies to, or null for an unscoped one.
  static List<String>? _taskScope(String line) {
    final match = _scopePattern.firstMatch(line);
    if (match == null) return null;
    return match.group(1)!.split(RegExp(r'\s+'));
  }

  /// [line] without its task scope.
  static String _unscoped(String line) {
    final match = _scopePattern.firstMatch(line);
    return match == null ? line : match.group(2)!.trim();
  }

  /// The names a scoped line may use for [task]: the task and its groups.
  List<String> _namesOf(String task) => <String>[
    task,
    ...?taskGroups[task],
  ];

  /// The `[options] mode` that applies to [task]: the first mode line in
  /// scope for it, else the file's first mode (for a null [task], or a file
  /// whose scopes this reader cannot place).
  String? modeFor(String? task) {
    if (task != null) {
      final names = _namesOf(task);
      for (final line in modeLines) {
        if (line.scope != null && line.appliesTo(names)) return line.text;
      }
      for (final line in modeLines) {
        if (line.appliesTo(names)) return line.text;
      }
    }
    return proofMode;
  }

  /// The `[script]` lines that run for [task], or every line for a null
  /// [task].
  List<String> scriptFor(String? task) {
    if (task == null) return script;
    final names = _namesOf(task);
    return <String>[
      for (final line in scriptLines)
        if (line.appliesTo(names)) line.text,
    ];
  }

  /// How the `[script]` for [task] turns assertions off, or null when it
  /// does not.
  ///
  /// `noassert` for Yosys's `-noassert` read option, `ignore_assertions`
  /// for yosys-slang's `--ignore-assertions`. A proof run that way checks
  /// no assertion at all, which a passing verdict does not say.
  String? assertionsDisabledFor(String? task) {
    for (final line in scriptFor(task)) {
      final words = line.split(RegExp(r'\s+'));
      if (words.contains('--ignore-assertions')) return 'ignore_assertions';
      if (words.contains('-noassert')) return 'noassert';
    }
    return null;
  }

  /// [assertionsDisabledFor] over every task: whether any task of the file
  /// turns assertions off.
  String? get assertionsDisabled {
    if (tasks.isEmpty) return assertionsDisabledFor(null);
    for (final task in tasks) {
      final how = assertionsDisabledFor(task);
      if (how != null) return how;
    }
    return null;
  }

  /// `[engines]` lines, task scope stripped, in file order
  /// (`smtbmc yices`, `abc pdr`).
  List<String> get engines => <String>[
    for (final line in engineLines) line.text,
  ];

  /// `[script]` lines, task scope stripped, in file order.
  List<String> get script => <String>[
    for (final line in scriptLines) line.text,
  ];

  /// `[options] mode …` — `bmc`, `prove`, `cover` or `live`.
  final String? proofMode;

  /// `[options] depth …` — the bound the proof was configured for.
  ///
  /// Reported as `riscv.formal.depth_configured` beside the depth
  /// actually reached, because "reached 12 of a configured 20" and
  /// "reached 12 of a configured 12" are different facts about a proof
  /// and the Pro dashboard has to tell them apart.
  final int? depth;

  /// `[options] timeout …`, in seconds, when the file sets one.
  final int? timeoutSeconds;

  /// Names from a `[tasks]` section, in declaration order. Empty for the
  /// single-task files `genchecks.py` produces.
  final List<String> tasks;

  /// `[files]`: the name each source has inside the task's `src/`
  /// directory, mapped to the path the `.sby` file gave for it (relative to
  /// the `.sby` file's directory, or absolute). Property locations in the
  /// status stream name the copy, so this is what maps them back to the
  /// user's file.
  final Map<String, String> files;

  /// The groups each `[tasks]` name joins (`prove_bug prove` puts task
  /// `prove_bug` in group `prove`), by task.
  final Map<String, List<String>> taskGroups;

  /// The `[options] mode` lines with their scopes; the text is the mode.
  final List<SbyScopedLine> modeLines;

  /// The `[engines]` lines with their scopes.
  final List<SbyScopedLine> engineLines;

  /// The `[script]` lines with their scopes.
  final List<SbyScopedLine> scriptLines;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SbyScript &&
        other.proofMode == proofMode &&
        other.depth == depth &&
        other.timeoutSeconds == timeoutSeconds &&
        other.tasks.length == tasks.length &&
        other.tasks.join('\x00') == tasks.join('\x00');
  }

  @override
  int get hashCode =>
      Object.hash(proofMode, depth, timeoutSeconds, Object.hashAll(tasks));

  @override
  String toString() =>
      'SbyScript(mode: $proofMode, depth: $depth, tasks: ${tasks.length})';
}

/// One line of a `.sby` section that may be task-scoped:
/// `prove: mode prove`, `~prove_bug: read -formal top.sv`.
@immutable
class SbyScopedLine {
  /// Creates a line.
  const SbyScopedLine({required this.text, this.scope});

  /// The scope's names (tasks or groups, a leading `~` negating one), or
  /// null for an unscoped line.
  final List<String>? scope;

  /// The line without its scope.
  final String text;

  /// Whether the line applies to a task known by [names] (the task and its
  /// groups): unscoped, named, or every name in a negated scope absent.
  bool appliesTo(List<String> names) {
    final scope = this.scope;
    if (scope == null) return true;
    final positive = scope.where((s) => !s.startsWith('~')).toList();
    if (positive.any(names.contains)) return true;
    final negative = <String>[
      for (final s in scope)
        if (s.startsWith('~')) s.substring(1),
    ];
    return positive.isEmpty &&
        negative.isNotEmpty &&
        !negative.any(names.contains);
  }
}
