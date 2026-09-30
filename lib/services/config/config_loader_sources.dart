// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

part of 'config_loader.dart';

/// Parses the `sources:` list, accepting both legacy syntax (bare
/// strings) and mixed-language syntax (object form with an
/// explicit `language:` override). Returns null when the field is
/// absent.
///
/// Both forms can be mixed in the same list:
///
/// ```yaml
/// sources:
///   - rtl/cpu.v                     # bare string, language inferred
///   - { path: rtl/legacy.txt,       # object form, explicit override
///       language: verilog }
/// ```
///
/// Recognized `language:` values: `auto`, `verilog`, `system_verilog`
/// / `systemverilog`, `vhdl`, `python`. `auto` (or omitting the
/// field) defers to extension-driven detection.
_SourcesParsed? _readSourceEntries(
  YamlMap map,
  List<String> path,
  String filePath,
  List<ConfigLoaderError> errors,
) {
  Object? node = map;
  YamlNode? currentNode = map;
  for (final key in path) {
    if (node is! YamlMap) return null;
    currentNode = node.nodes[key];
    node = node[key];
  }
  if (node == null) return null;
  if (node is! YamlList) {
    errors.add(
      _error(
        path: filePath,
        node: currentNode,
        message:
            '`${path.join('.')}` must be a list of strings or '
            '`{path, language}` maps.',
      ),
    );
    return null;
  }
  final paths = <String>[];
  final languages = <String, HdlLanguage>{};
  for (final entry in node.nodes) {
    final raw = entry.value;
    if (raw is String) {
      if (raw.isEmpty) {
        errors.add(
          _error(
            path: filePath,
            node: entry,
            message: 'Source entries must be non-empty strings or maps.',
          ),
        );
        continue;
      }
      paths.add(raw);
    } else if (entry is YamlMap) {
      final entryPath = entry['path'];
      if (entryPath is! String || entryPath.isEmpty) {
        errors.add(
          _error(
            path: filePath,
            node: entry,
            message: 'Source entry must include a non-empty `path:` field.',
          ),
        );
        continue;
      }
      paths.add(entryPath);
      final langRaw = entry['language'];
      if (langRaw == null || langRaw == 'auto') {
        // No override.
      } else if (langRaw is String) {
        final parsed = _parseHdlLanguage(langRaw);
        if (parsed == null) {
          errors.add(
            _error(
              path: filePath,
              node: entry.nodes['language'],
              message:
                  'Source `$entryPath`: unknown language "$langRaw" '
                  '(expected auto / verilog / systemverilog / vhdl / '
                  'python).',
            ),
          );
        } else {
          languages[entryPath] = parsed;
        }
      } else {
        errors.add(
          _error(
            path: filePath,
            node: entry.nodes['language'],
            message: 'Source `$entryPath`: `language` must be a string.',
          ),
        );
      }
    } else {
      errors.add(
        _error(
          path: filePath,
          node: entry,
          message:
              'Each `${path.join('.')}` entry must be a string or '
              '`{path, language}` map.',
        ),
      );
    }
  }
  return _SourcesParsed(paths: paths, languages: languages);
}

/// Private return type of [_readSourceEntries]: the unmodifiable
/// source-path list plus the per-source language overrides map. Pulled
/// into a typed pair (rather than `(List, Map)`) for clarity at the
/// call sites.
class _SourcesParsed {
  _SourcesParsed({
    required List<String> paths,
    required Map<String, HdlLanguage> languages,
  }) : paths = List<String>.unmodifiable(paths),
       languages = Map<String, HdlLanguage>.unmodifiable(languages);

  final List<String> paths;
  final Map<String, HdlLanguage> languages;
}
