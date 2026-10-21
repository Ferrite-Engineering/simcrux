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
/// headers, the `[options]` key/value lines and the `[tasks]` names, and
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
  });

  /// Parses [text]. Never throws: an unreadable or unusual file yields an
  /// all-null result, and the driver simply reports fewer metrics.
  factory SbyScript.parse(String text) {
    String? mode;
    int? depth;
    int? timeout;
    final tasks = <String>[];
    final files = <String, String>{};
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
        // scope is stripped so the unscoped default is still read.
        final scoped = line.contains(':')
            ? line.substring(line.indexOf(':') + 1).trim()
            : line;
        final parts = scoped.split(RegExp(r'\s+'));
        if (parts.length < 2) continue;
        switch (parts.first) {
          case 'mode':
            mode ??= parts[1];
          case 'depth':
            depth ??= int.tryParse(parts[1]);
          case 'timeout':
            timeout ??= int.tryParse(parts[1]);
        }
      } else if (section == 'tasks') {
        // `<task> [<group> …]` — only the first token names the task.
        final name = line.split(RegExp(r'\s+')).first;
        if (name.isNotEmpty && !tasks.contains(name)) tasks.add(name);
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
    );
  }

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
