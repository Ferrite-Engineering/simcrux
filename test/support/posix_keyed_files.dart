// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:path/path.dart' as p;

/// The posix form of [path], whatever host produced it: separators are `/`,
/// `.` and `..` segments are folded, and a drive prefix is dropped, so
/// `D:\proj\sub.yaml`, `D:/proj/./sub.yaml` and `/proj/sub.yaml` all become
/// `/proj/sub.yaml`.
///
/// A loader that absolutises a fixture path through `package:path` returns a
/// drive-qualified, backslash path on Windows, and an in-memory file map keyed
/// by the readable posix spelling then matches nothing. Keying the map by this
/// form keeps the fixtures readable and the lookup host-independent.
///
/// Windows-style splitting is used on purpose: it understands both separators
/// on every host, where the posix context would treat `D:\proj\sub.yaml` as
/// one file name. A relative path stays relative.
String posixKey(String path) {
  final segments = p.windows.split(path);
  if (segments.isEmpty) return path;
  final absolute = p.windows.isAbsolute(path);
  final rest = absolute ? segments.skip(1) : segments;
  final joined = p.posix.joinAll(rest);
  return p.posix.normalize(absolute ? p.posix.join('/', joined) : joined);
}

/// A `readFile` callback over [files], whose keys are posix paths, that finds
/// a file by the posix form of the path it is asked for. An unknown path
/// throws a [StateError] naming both spellings.
Future<String> Function(String path) readFromPosixKeyed(
  Map<String, String> files,
) {
  final byKey = {for (final e in files.entries) posixKey(e.key): e.value};
  return (path) async =>
      byKey[posixKey(path)] ??
      (throw StateError('no ${posixKey(path)} (asked for $path)'));
}
