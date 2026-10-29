// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_flow/crux_flow.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/flow_config.dart';

/// A LibreLane design directory LibreLane cannot run from, and the first
/// character in it that stops the run.
@immutable
class LibreLaneUnsupportedPath {
  /// Creates the refusal.
  const LibreLaneUnsupportedPath({required this.path, required this.character});

  /// The design directory as LibreLane is handed it, symlinks resolved.
  final String path;

  /// The first unsupported character in [path].
  final String character;

  /// Whether [character] is a plain space, the common case (a folder such
  /// as `Getting Started`), which the messages name in words.
  bool get isSpace => character == ' ';

  /// [character] as a message names it: its code point, and the character
  /// itself when it prints (`U+0022 (")`, `U+0009`).
  String get characterLabel {
    final code = character.runes.first;
    final hex = code.toRadixString(16).toUpperCase().padLeft(4, '0');
    final printable = code > 0x20 && code != 0x7F;
    return printable ? 'U+$hex ($character)' : 'U+$hex';
  }

  /// The English sentence the driver and the CLI report. The GUI shows the
  /// localized one (`FlowLabels.unsupportedPath`).
  String get message => isSpace
      ? 'LibreLane cannot run this design: its directory path contains a '
            'space, which LibreLane does not support. Move the project, or '
            'run it from a path without spaces. Path: $path'
      : 'LibreLane cannot run this design: its directory path contains the '
            'character $characterLabel, which LibreLane does not support. '
            'Move the project, or run it from a path without spaces, tabs, '
            'line breaks, double quotes or backslashes. Path: $path';
}

/// The design directories LibreLane cannot run from, found before a run is
/// launched.
///
/// LibreLane writes its run, `runs/<tag>/`, under the design directory and
/// passes paths inside it to its tools without quoting them, so two of its
/// steps break on characters in that path (LibreLane 3.0.16):
///
/// - the cell-model blackboxing (`Toolbox.create_blackbox_model`) hands
///   Yosys `read_verilog -sv -lib <run>/tmp/<hash>.bb.v` in a `-p` script,
///   and Yosys splits a script on space, tab, carriage return and line feed,
///   so the models never load and the Verilator lint fails on the first PDK
///   cell it cannot resolve;
/// - the Verilator lint writes `lint_off -rule <rule> -file "<path>"` for
///   every blackbox into its `_deps.vlt`, where a double quote ends the
///   string and a backslash starts an escape, and Verilator stops on the
///   malformed configuration.
///
/// Nothing else is refused: other punctuation and non-ASCII letters run.
/// The path checked is the one LibreLane is handed, the configuration's
/// directory with every symlink resolved, because that is the path its
/// tools see: a link without a space into a folder with one does not help.
/// Reading a finished run (ingest) never goes through this check.
abstract final class LibreLanePathCheck {
  /// The characters a LibreLane design directory cannot contain.
  static const Set<String> kUnsupported = <String>{
    ' ',
    '\t',
    '\r',
    '\n',
    '"',
    r'\',
  };

  /// The first unsupported character in [designDirectory], or null when
  /// LibreLane can run from it. The root prefix (`C:\` on Windows) and the
  /// separators are not part of any name and are not checked.
  static LibreLaneUnsupportedPath? check(String designDirectory) {
    final parts = p.split(designDirectory);
    final root = p.rootPrefix(designDirectory);
    for (var i = 0; i < parts.length; i++) {
      if (i == 0 && root.isNotEmpty && parts[0] == root) continue;
      for (final rune in parts[i].runes) {
        final c = String.fromCharCode(rune);
        if (kUnsupported.contains(c)) {
          return LibreLaneUnsupportedPath(path: designDirectory, character: c);
        }
      }
    }
    return null;
  }

  /// [entry]'s design directory, resolved as the LibreLane driver resolves
  /// it, checked. Null when it is supported, when [entry] is not a
  /// LibreLane entry, or when it cannot be resolved (the driver says why
  /// itself when it runs).
  static LibreLaneUnsupportedPath? forEntry(FlowEntry entry) {
    if (entry.kind != FlowKind.librelane) return null;
    final root = entry.projectRoot;
    final config = entry.config;
    if (root == null || config == null) return null;
    try {
      final resolved = FlowContainment(<String>[root]).require(config);
      return check(p.dirname(resolved));
    } on FlowContainmentException {
      return null;
    }
  }
}
