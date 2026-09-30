// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/config_loader_error.dart';

/// Result of expanding a single Verilog-style `.f` filelist file.
class FilelistExpansion {
  /// Creates a [FilelistExpansion].
  FilelistExpansion({
    required List<String> sources,
    required List<String> includeDirs,
    required Map<String, String> defines,
  }) : sources = List<String>.unmodifiable(sources),
       includeDirs = List<String>.unmodifiable(includeDirs),
       defines = Map<String, String>.unmodifiable(defines);

  /// Source file paths the `.f` file contributed.
  final List<String> sources;

  /// `+incdir+` / `-I` directives from the `.f` file.
  final List<String> includeDirs;

  /// `+define+` / `-D` directives from the `.f` file.
  final Map<String, String> defines;
}

/// Reads and expands a Verilog/SystemVerilog-style `.f` filelist file.
///
/// Format support (intersected from common simulator-tool conventions):
///
/// - One source path per line. Blank lines and lines starting with
///   `#` or `//` are ignored as comments.
/// - `+incdir+path` — added to [FilelistExpansion.includeDirs].
/// - `+define+KEY=VALUE` — added to [FilelistExpansion.defines].
/// - `-I<path>` and `-I <path>` — same as `+incdir+`.
/// - `-D<KEY=VALUE>` and `-D <KEY=VALUE>` — same as `+define+`.
///
/// Paths inside the `.f` file are resolved **relative to the
/// `.f` file's own directory**. The expander returns paths as
/// already-resolved relative paths from [projectRoot] so the
/// downstream scheduler / driver can pass them to simulators from a
/// known cwd.
class FilelistExpander {
  /// Creates a [FilelistExpander].
  ///
  /// [readFile] is injected so tests can drive the expander against an
  /// in-memory map. Defaults to a synchronous filesystem read.
  FilelistExpander({Future<String> Function(String path)? readFile})
    : _readFile = readFile ?? _defaultReadFile;

  final Future<String> Function(String path) _readFile;

  static Future<String> _defaultReadFile(String path) =>
      File(path).readAsString();

  /// Expand a single `.f` file located at [filelistPath].
  ///
  /// [projectRoot] is the absolute directory of the originating
  /// `simcrux.yaml`. Source paths inside the `.f` file are resolved
  /// relative to the `.f` file's directory, then made relative to
  /// [projectRoot] in the returned [FilelistExpansion]. Throws
  /// [ConfigLoaderException] for malformed lines so callers can
  /// surface a clear error.
  Future<FilelistExpansion> expand({
    required String filelistPath,
    required String projectRoot,
  }) async {
    final absFilelist = p.normalize(p.absolute(filelistPath));
    final filelistDir = p.dirname(absFilelist);

    final String contents;
    try {
      contents = await _readFile(absFilelist);
    } on Object catch (e) {
      throw ConfigLoaderException([
        ConfigLoaderError.generic(
          path: absFilelist,
          message: 'Could not read filelist `$filelistPath`: $e',
        ),
      ]);
    }

    final sources = <String>[];
    final includeDirs = <String>[];
    final defines = <String, String>{};
    final errors = <ConfigLoaderError>[];

    var lineNo = 0;
    for (final raw in contents.split('\n')) {
      lineNo++;
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#') || line.startsWith('//')) continue;

      if (line.startsWith('+incdir+')) {
        final value = line.substring('+incdir+'.length).trim();
        if (value.isEmpty) {
          errors.add(
            _lineError(absFilelist, lineNo, '`+incdir+` requires a path.'),
          );
          continue;
        }
        includeDirs.add(_resolveAgainst(value, filelistDir, projectRoot));
        continue;
      }
      if (line.startsWith('+define+')) {
        final value = line.substring('+define+'.length).trim();
        if (!_addDefine(value, defines)) {
          errors.add(
            _lineError(
              absFilelist,
              lineNo,
              '`+define+` requires KEY=VALUE.',
            ),
          );
        }
        continue;
      }
      if (line.startsWith('-I')) {
        final rest = line.substring(2).trim();
        if (rest.isEmpty) {
          errors.add(_lineError(absFilelist, lineNo, '`-I` requires a path.'));
          continue;
        }
        includeDirs.add(_resolveAgainst(rest, filelistDir, projectRoot));
        continue;
      }
      if (line.startsWith('-D')) {
        final rest = line.substring(2).trim();
        if (!_addDefine(rest, defines)) {
          errors.add(
            _lineError(
              absFilelist,
              lineNo,
              '`-D` requires KEY=VALUE.',
            ),
          );
        }
        continue;
      }

      // Default: treat the line as a source path.
      sources.add(_resolveAgainst(line, filelistDir, projectRoot));
    }

    if (errors.isNotEmpty) throw ConfigLoaderException(errors);

    return FilelistExpansion(
      sources: sources,
      includeDirs: includeDirs,
      defines: defines,
    );
  }

  /// Returns true on success; false when [value] is not a valid
  /// `KEY=VALUE` (or bare-`KEY`, treated as `KEY=1`).
  bool _addDefine(String value, Map<String, String> sink) {
    if (value.isEmpty) return false;
    final eq = value.indexOf('=');
    if (eq < 0) {
      sink[value] = '1';
      return true;
    }
    final key = value.substring(0, eq).trim();
    final v = value.substring(eq + 1).trim();
    if (key.isEmpty) return false;
    sink[key] = v;
    return true;
  }

  /// Resolves [pathInFilelist] (which is relative to [filelistDir],
  /// per the .f convention) to a path that is relative to
  /// [projectRoot]. Absolute paths pass through unchanged.
  String _resolveAgainst(
    String pathInFilelist,
    String filelistDir,
    String projectRoot,
  ) {
    if (p.isAbsolute(pathInFilelist)) return pathInFilelist;
    final abs = p.normalize(p.join(filelistDir, pathInFilelist));
    return p.relative(abs, from: projectRoot);
  }

  ConfigLoaderError _lineError(String path, int line, String message) {
    return ConfigLoaderError(
      path: path,
      message: message,
      line: line,
    );
  }
}
