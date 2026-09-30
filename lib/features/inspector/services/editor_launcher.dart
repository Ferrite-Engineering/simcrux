// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_io/crux_io.dart';
import 'package:simcrux/domain/models/app_settings.dart';

/// Shells out to the user's editor to open a source file at a given
/// line / column.
///
/// Driven by [AppSettings.editorCommandTemplate]. The **template** is
/// tokenized on whitespace first — the first token becomes the
/// executable name and the rest become the argument list — and only
/// then are `{file}`, `{line}`, `{column}` substituted, once per argv
/// element.
///
/// The order matters and is load-bearing, not stylistic. The three
/// call sites in `inbound_request_handler.dart` hand this class a
/// `filePath` that arrived over CXP from a peer, and
/// `cxpServerEnabled` defaults to true. Containment (below) bounds
/// *which* file a peer can name, not what characters its path holds —
/// a directory the user opened may itself contain spaces. A
/// substitute-then-split launcher would let a peer path of
/// `'a --install-extension attacker.evil --goto b'` split into fresh
/// argv elements and turn `code --goto {file}` into an extension
/// install. Substituting per element keeps any whitespace the peer
/// supplied inside the single argument it was substituted into.
///
/// This is the same shape LintCrux's `EditorCommand.render()` and
/// NetCrux's `EditorOpenService.openSourceLocation` use; all three
/// products substitute per argv element.
///
/// Two more checks sit between the template and the spawn, both from
/// `crux_io`, the suite's one copy of each:
///
/// - **The file must be an absolute path** ([isAbsoluteSpawnPath]). The
///   common templates put a line number in an argument beginning with `+`,
///   and to `vim` and `emacs` an argument beginning with `+` is a command,
///   not a file. An absolute path is the one shape no editor's option parser
///   reads as a flag, so anything else is refused before the spawn, whoever
///   supplied it.
/// - **The executable is resolved before it is spawned**
///   ([SpawnHost.requireExecutable]). On Windows a bare name such as `code`
///   is otherwise searched for in the directory SimCrux was launched from
///   before `PATH`, so a `code.exe` committed to the repository the user
///   `cd`'d into would run instead of the editor. An editor that is not on
///   `PATH` is reported as a failed launch, with nothing spawned.
///
/// What this deliberately does **not** do is quote or escape: the
/// executable and arguments go to `Process.start` as a real argv, with
/// no shell in between, so there is nothing to escape. Nor does it
/// validate that [filePath] looks like a path — a value that happens to
/// equal a flag (`--foo`) is still passed as one argument, and a
/// template of `code {file}` would hand the editor that flag. That is
/// the caller's rule to apply, and for a peer-supplied path it is
/// applied: CXP authenticates the sender (it must present the token
/// this process published in its discovery manifest), and the inbound
/// request handler refuses a path that is not absolute or lies outside
/// the directories the user has opened (`CxpPathContainment`, CXP §11)
/// before it ever reaches this class.
class EditorLauncher {
  /// Creates an [EditorLauncher].
  ///
  /// [processStarter] is injectable for tests. The default uses
  /// `Process.start` from `dart:io`. [spawnHost] supplies the host facts
  /// the executable is resolved against, and defaults to the live process;
  /// tests pass a Windows host with a synthetic `PATH`.
  EditorLauncher({
    required this.template,
    Future<Process> Function(String, List<String>)? processStarter,
    SpawnHost? spawnHost,
  }) : _processStarter = processStarter ?? _defaultStart,
       // Private, so test doubles that implement this class need not; a
       // named parameter cannot be an initializing formal for it.
       // ignore: prefer_initializing_formals
       _spawnHost = spawnHost;

  /// The active command template (e.g.
  /// `'code --goto {file}:{line}:{column}'`).
  final String template;

  final Future<Process> Function(String, List<String>) _processStarter;

  /// The host facts the executable is resolved against. Null means the
  /// live process, read at launch time.
  final SpawnHost? _spawnHost;

  static Future<Process> _defaultStart(
    String executable,
    List<String> args,
  ) => Process.start(executable, args, mode: ProcessStartMode.detached);

  /// Compute the executable and argument list for the configured
  /// template. Returns null when the template is empty or
  /// malformed (no executable token after stripping leading
  /// whitespace).
  ///
  /// [filePath] may be peer-supplied over CXP — see the class doc. The
  /// template is tokenized before substitution so no value of
  /// [filePath] can add, remove, or reorder argv elements.
  ({String executable, List<String> args})? composeCommand({
    required String filePath,
    int line = 1,
    int column = 1,
  }) {
    // Tokenize the TEMPLATE — which only the local user can set, via
    // Settings → Editor — and never the substituted string.
    final tokens = template
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList(growable: false);
    if (tokens.isEmpty) return null;
    final substituted = tokens
        .map(
          (t) => t
              .replaceAll('{file}', filePath)
              .replaceAll('{line}', line.toString())
              .replaceAll('{column}', column.toString()),
        )
        .toList(growable: false);
    return (
      executable: substituted.first,
      args: substituted.sublist(1),
    );
  }

  /// Launch the editor for [filePath] at [line]:[column]. Returns
  /// false when [filePath] is not an absolute path, the template is
  /// malformed, the editor is not on `PATH` (Windows), or it failed to
  /// launch; true otherwise.
  Future<bool> openSource({
    required String filePath,
    int line = 1,
    int column = 1,
  }) async {
    if (!isAbsoluteSpawnPath(filePath)) return false;
    final cmd = composeCommand(
      filePath: filePath,
      line: line,
      column: column,
    );
    if (cmd == null) return false;
    try {
      // Throws the same ProcessException a missing binary does, which the
      // catch below reports as a failed launch. Never retried with the bare
      // name: that is the search this exists to prevent.
      final executable = (_spawnHost ?? SpawnHost.current()).requireExecutable(
        cmd.executable,
      );
      await _processStarter(executable, cmd.args);
      return true;
    } on Object {
      return false;
    }
  }
}
