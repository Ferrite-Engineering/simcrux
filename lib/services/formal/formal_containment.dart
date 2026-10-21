// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_io/crux_io.dart';
import 'package:path/path.dart' as p;

/// Path containment for the formal drivers, shared by every caller that
/// turns a name from a project file or a tool's output into a path.
///
/// Two rules, one file, so the RISC-V track, the general `sby` driver and
/// the config loader cannot drift apart:
///
/// - **A work or task directory is one safe path segment.** `sby -f`
///   deletes its `-d` directory before it runs, so a name that is not a
///   single plain segment would have SymbiYosys delete a directory SimCrux
///   never created. Both separator spellings are refused on every host, so
///   a project file that loads on macOS cannot turn into a path on Windows.
/// - **A path a tool announced is used only inside the directory it
///   belongs to.** Resolution goes through `crux_io` path identity, so a
///   symlink inside the task directory that points out of it is refused
///   like a `../` spelling.
abstract final class FormalContainment {
  /// Why [value] is not a single safe path segment, or null when it is.
  ///
  /// Refused: empty, NUL, a line break, an absolute path in either the
  /// POSIX or the Windows spelling, `.` and `..`, either separator, and a
  /// colon (a Windows drive-relative name such as `C:x`, or an NTFS
  /// alternate data stream).
  static String? segmentProblem(String value) {
    if (value.isEmpty) return 'it is empty';
    if (value.contains('\u0000')) return 'it contains a NUL byte';
    if (value.contains('\n') || value.contains('\r')) {
      return 'it contains a line break';
    }
    if (p.posix.isAbsolute(value) || p.windows.isAbsolute(value)) {
      return 'it is an absolute path';
    }
    if (value == '.' || value == '..') {
      return 'it names the working directory or its parent';
    }
    if (value.contains('/') || value.contains(r'\')) {
      return 'it contains a path separator';
    }
    if (value.contains(':')) return 'it contains a drive or stream colon';
    return null;
  }

  /// [relative] joined onto [root], or null unless the result is strictly
  /// inside [root].
  ///
  /// An absolute [relative] is accepted only when it already lies inside
  /// [root]. Both sides are canonicalised (absolute, normalised, symlinks
  /// resolved where the path exists), so `/tmp` and `/private/tmp` agree on
  /// macOS and a link that leaves [root] is refused.
  static String? containedPath(String root, String relative) {
    if (relative.isEmpty || relative.contains('\u0000')) return null;
    final joined = p.isAbsolute(relative) ? relative : p.join(root, relative);
    final candidate = p.normalize(p.absolute(joined));
    final canonicalRoot = _canonical(p.normalize(p.absolute(root)));
    if (!p.isWithin(canonicalRoot, _canonical(candidate))) return null;
    return candidate;
  }

  /// [path] with every symlink in its deepest existing ancestor resolved
  /// and the not-yet-existing rest appended, so a file that does not exist
  /// yet compares on the same footing as its directory.
  static String _canonical(String path) {
    var existing = path;
    final rest = <String>[];
    while (FileSystemEntity.typeSync(existing, followLinks: false) ==
        FileSystemEntityType.notFound) {
      final parent = p.dirname(existing);
      if (parent == existing) return path;
      rest.insert(0, p.basename(existing));
      existing = parent;
    }
    final resolved = canonicalizePath(existing);
    return rest.isEmpty ? resolved : p.joinAll(<String>[resolved, ...rest]);
  }
}
