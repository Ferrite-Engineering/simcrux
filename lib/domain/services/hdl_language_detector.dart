// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/hdl_language.dart';

/// Pure-Dart utility that maps a source file path to its HDL language
/// based on the file extension.
///
/// Used by the config loader to:
///
/// - infer a per-source `language:` when the user did not declare it
///   explicitly,
/// - cross-check the declared simulator's
///   [SimulatorCapabilities.supportedLanguages] against the test's
///   source list, surfacing a clear error when the configured
///   simulator cannot handle the test (e.g. `icarus` on a `.vhd`),
/// - drive Cocotb's `TOPLEVEL_LANG` routing by majority-language vote.
///
/// The detector is intentionally *only* extension-based — content
/// sniffing is out of scope. Engineering teams overwhelmingly stick to
/// the conventional extensions, and the explicit
/// `sources: [{path: "x.foo", language: vhdl}]` syntax already
/// covers the edge case of non-conventional file names.
class HdlLanguageDetector {
  /// Creates an [HdlLanguageDetector].
  const HdlLanguageDetector();

  /// Returns the inferred [HdlLanguage] for [path], or `null` when the
  /// extension is unrecognized.
  ///
  /// Extension table (case-insensitive):
  ///
  /// | Extension       | Language                |
  /// |-----------------|-------------------------|
  /// | `.v`            | [HdlLanguage.verilog]   |
  /// | `.sv`, `.svh`   | [HdlLanguage.systemVerilog] |
  /// | `.vh`           | [HdlLanguage.verilog]   (Verilog header) |
  /// | `.vhd`, `.vhdl` | [HdlLanguage.vhdl]      |
  /// | `.py`           | [HdlLanguage.python]    (Cocotb testbench) |
  /// | anything else   | `null`                  |
  HdlLanguage? detect(String path) {
    final ext = p.extension(path).toLowerCase();
    switch (ext) {
      case '.v':
      case '.vh':
        return HdlLanguage.verilog;
      case '.sv':
      case '.svh':
        return HdlLanguage.systemVerilog;
      case '.vhd':
      case '.vhdl':
        return HdlLanguage.vhdl;
      case '.py':
        return HdlLanguage.python;
      default:
        return null;
    }
  }

  /// Returns the *dominant* language across [paths] — the language
  /// with the highest count among files whose language was detected.
  /// Ties break in the order
  /// `verilog → systemVerilog → vhdl → python`. Returns `null` only
  /// when no path's language could be inferred.
  ///
  /// Used by Cocotb's `TOPLEVEL_LANG` routing: a mixed-language
  /// project under Cocotb runs through one underlying simulator at a
  /// time, and Cocotb's Makefile expects a single TOPLEVEL_LANG. The
  /// dominant-language heuristic picks the most likely answer; the
  /// user can override per-test via `parameters.TOPLEVEL_LANG`.
  HdlLanguage? dominantLanguage(Iterable<String> paths) {
    final counts = <HdlLanguage, int>{};
    for (final path in paths) {
      final lang = detect(path);
      if (lang == null) continue;
      counts[lang] = (counts[lang] ?? 0) + 1;
    }
    if (counts.isEmpty) return null;
    HdlLanguage? best;
    var bestCount = -1;
    for (final order in const [
      HdlLanguage.verilog,
      HdlLanguage.systemVerilog,
      HdlLanguage.vhdl,
      HdlLanguage.python,
    ]) {
      final c = counts[order] ?? 0;
      if (c > bestCount) {
        bestCount = c;
        best = order;
      }
    }
    return best;
  }
}
