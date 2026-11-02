// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

/// The names of the named scopes at the top of the VCD at [path], in the
/// order the header declares them, without repeats.
///
/// Only the header is read, up to `$enddefinitions` or [maxBytes], whichever
/// comes first; no value change is ever parsed. Variables declared above every
/// scope (a solver's clock, say) are not scopes and are skipped.
///
/// Empty when the file is missing, unreadable or declares no scope.
///
/// A formal run's trace is rooted at the design the job script elaborated
/// (`prep -top handshake`), which is not the name SimCrux gave the test: the
/// importers name a test after its task or check. This is how a hand-off
/// finds the scope that actually holds the design's signals.
Future<List<String>> vcdTopLevelScopes(
  String path, {
  int maxBytes = 64 * 1024 * 1024,
}) async {
  final scopes = <String>[];
  try {
    final file = File(path);
    if (!file.existsSync()) return scopes;
    final tokens = _VcdHeaderTokens(scopes);
    var read = 0;
    await for (final chunk in file.openRead().transform(latin1.decoder)) {
      read += chunk.length;
      if (tokens.feed(chunk) || read >= maxBytes) break;
    }
  } on Object {
    // A trace that cannot be read has no scopes to offer; the hand-off still
    // opens it.
  }
  return scopes;
}

/// Reads a VCD header as a stream of whitespace-separated tokens, keeping
/// track of scope depth. Inside a command only `$end` means anything: a
/// variable may be called `$procmux$12`, and a comment may mention `$scope`.
class _VcdHeaderTokens {
  _VcdHeaderTokens(this._topLevel);

  final List<String> _topLevel;
  final StringBuffer _partial = StringBuffer();
  String? _command;
  final List<String> _scopeArguments = <String>[];
  int _depth = 0;

  /// Feeds [chunk]; true once `$enddefinitions` has been seen.
  bool feed(String chunk) {
    var start = 0;
    for (var i = 0; i < chunk.length; i++) {
      if (!_isSpace(chunk.codeUnitAt(i))) continue;
      if (i > start) _partial.write(chunk.substring(start, i));
      start = i + 1;
      if (_flush()) return true;
    }
    if (start < chunk.length) _partial.write(chunk.substring(start));
    return false;
  }

  static bool _isSpace(int c) => c == 0x20 || c == 0x0A || c == 0x0D || c == 9;

  bool _flush() {
    if (_partial.isEmpty) return false;
    final token = _partial.toString();
    _partial.clear();
    return _token(token);
  }

  bool _token(String token) {
    final command = _command;
    if (command == null) {
      if (token == r'$enddefinitions') return true;
      if (token.startsWith(r'$')) {
        _command = token;
        _scopeArguments.clear();
      }
      return false;
    }
    if (token != r'$end') {
      if (command == r'$scope') _scopeArguments.add(token);
      return false;
    }
    _command = null;
    if (command == r'$scope') {
      // `$scope <type> <name> $end`
      if (_depth == 0 && _scopeArguments.length >= 2) {
        final name = _scopeArguments[1];
        if (!_topLevel.contains(name)) _topLevel.add(name);
      }
      _depth++;
    } else if (command == r'$upscope') {
      if (_depth > 0) _depth--;
    }
    return false;
  }
}
