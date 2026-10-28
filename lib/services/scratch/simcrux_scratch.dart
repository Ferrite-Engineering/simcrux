// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// SimCrux's own scratch: the one base that gate-level simulation's generated
/// files, zipped-artifact extraction and the job scheduler's per-test work
/// directories live under by default.
///
/// * **Linux:** `${XDG_CACHE_HOME:-$HOME/.cache}/simcrux`. The system
///   temporary directory there is normally the shared `/tmp`, where a fixed
///   name can be made first by another user of the machine, who would then
///   own the directory SimCrux writes generated Verilog into.
/// * **Elsewhere:** `simcrux` in the system temporary directory, which macOS
///   and Windows keep per user.
///
/// A missing base is made private (it is created as a fresh temporary
/// directory, set to `0700`, and moved into place), and every use checks
/// it: a base that is a symbolic link, is not a directory, that group or
/// others can write, or that belongs to another user is refused with a
/// [FileSystemException] rather than written into.
abstract final class SimcruxScratch {
  /// The name of the base directory.
  static const String kName = 'simcrux';

  /// Group and other write bits; neither may be set on a base.
  static const int _groupOrOtherWrite = 0x12; // 0o022

  static String? _fallback;

  /// Bases already found to be this user's, so the ownership probe runs once
  /// per base per process rather than for every test's work directory.
  static final Set<String> _owned = <String>{};

  /// Runs `chmod`. Replaced by tests to stand in for a base that belongs to
  /// another user, which a test cannot make without privilege.
  @visibleForTesting
  static ProcessResult Function(String executable, List<String> arguments)
  runProcess = Process.runSync;

  /// The `chmod` to run: `/bin/chmod` or `/usr/bin/chmod` when either exists,
  /// else `chmod` found on `PATH` (NixOS has neither fixed path).
  @visibleForTesting
  static String chmodExecutable({bool Function(String path)? exists}) {
    final present = exists ?? (String path) => File(path).existsSync();
    for (final candidate in const <String>['/bin/chmod', '/usr/bin/chmod']) {
      if (present(candidate)) return candidate;
    }
    return 'chmod';
  }

  /// Forgets which bases were found to be this user's.
  @visibleForTesting
  static void resetForTesting() => _owned.clear();

  /// The default base on this machine.
  ///
  /// [environment], [operatingSystem] and [systemTemp] default to this
  /// process's and exist for tests. A Linux session with neither an absolute
  /// `XDG_CACHE_HOME` nor an absolute `HOME` gets a fresh temporary
  /// directory, made once per process and set to `0700`, rather than a
  /// predictable name.
  static String defaultBase({
    Map<String, String>? environment,
    String? operatingSystem,
    String? systemTemp,
  }) {
    final os = operatingSystem ?? Platform.operatingSystem;
    final temp = systemTemp ?? Directory.systemTemp.path;
    if (os != 'linux') return p.join(temp, kName);
    final env = environment ?? Platform.environment;
    final cache = env['XDG_CACHE_HOME'];
    if (cache != null && cache.isNotEmpty && p.posix.isAbsolute(cache)) {
      return p.posix.join(cache, kName);
    }
    final home = env['HOME'];
    if (home != null && home.isNotEmpty && p.posix.isAbsolute(home)) {
      return p.posix.join(home, '.cache', kName);
    }
    return _fallback ??= _makePrivate(
      Directory(temp).createTempSync('$kName-').path,
    );
  }

  /// Where gate-level simulation writes its generated port-dump modules and
  /// port dumps by default.
  static String gateLevel() => p.join(defaultBase(), 'gls');

  /// Where zipped artifacts are extracted by default.
  static String ingest() => p.join(defaultBase(), 'ingest');

  /// The job scheduler's default run root (it adds `runs/<runId>/<test>`).
  static String jobs() => defaultBase();

  /// Makes [dir] inside [base] (which may be [dir] itself) and returns [dir].
  ///
  /// [base] is created private when it is missing and then checked; one that
  /// is a symbolic link, is not a directory, that group or others can write,
  /// or that belongs to another user throws a [FileSystemException] naming
  /// it, and nothing is created inside.
  static String prepare(String dir, {required String base}) {
    _ensureBase(base);
    if (!p.equals(dir, base)) Directory(dir).createSync(recursive: true);
    return dir;
  }

  /// Why [base] may not be used, or null when it may. Nothing is created.
  static String? refusal(String base, {bool? isWindows}) {
    final type = FileSystemEntity.typeSync(base, followLinks: false);
    if (type == FileSystemEntityType.link) {
      return 'it is a symbolic link';
    }
    if (type != FileSystemEntityType.directory) {
      return 'it is not a directory';
    }
    // Windows has access-control lists rather than modes; the base there is
    // in the user's own temporary directory.
    if (isWindows ?? Platform.isWindows) return null;
    final mode = FileStat.statSync(base).mode;
    if (mode & _groupOrOtherWrite != 0) {
      return 'other users of this machine can write to it';
    }
    return null;
  }

  static void _ensureBase(String base) {
    if (FileSystemEntity.typeSync(base, followLinks: false) ==
        FileSystemEntityType.notFound) {
      final parent = Directory(p.dirname(base))..createSync(recursive: true);
      // A new directory takes the umask's mode (0775 under a umask of 002),
      // so it is made 0700 before it appears under its own name.
      final fresh = _makePrivate(parent.createTempSync('.$kName-').path);
      try {
        Directory(fresh).renameSync(base);
      } on FileSystemException {
        // Made by another SimCrux process in between: it is checked below
        // like any existing base.
        try {
          Directory(fresh).deleteSync();
        } on FileSystemException {
          // Left behind empty; harmless.
        }
      }
    }
    final why = refusal(base) ?? _ownership(base);
    if (why != null) {
      throw FileSystemException(
        'SimCrux will not use this scratch directory: $why',
        base,
      );
    }
  }

  /// Sets [path] to `0700` and returns it. dart:io sets no mode, so this runs
  /// chmod(1); when it cannot, the mode check that follows every use refuses
  /// a directory other users can write.
  static String _makePrivate(String path) {
    if (Platform.isWindows) return path;
    try {
      runProcess(chmodExecutable(), <String>['700', path]);
    } on ProcessException {
      // Left to the mode check.
    }
    return path;
  }

  /// Why [base] may not be used because it is not this user's, or null.
  ///
  /// dart:io reports no owner, so the probe is `chmod u+rwx`: only the owner
  /// may change a directory's mode, and the owner bits of a usable base are
  /// already set, so for the user's own base nothing changes. A base on
  /// someone else's path in `XDG_CACHE_HOME`, made by them with mode 0755,
  /// fails it. When chmod cannot be run at all the check is skipped, as on
  /// Windows, and the mode check alone applies.
  static String? _ownership(String base) {
    if (Platform.isWindows || _owned.contains(base)) return null;
    final ProcessResult result;
    try {
      result = runProcess(chmodExecutable(), <String>['u+rwx', base]);
    } on ProcessException {
      return null;
    }
    if (result.exitCode != 0) {
      return 'it belongs to another user';
    }
    _owned.add(base);
    return null;
  }
}
