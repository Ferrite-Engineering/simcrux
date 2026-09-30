// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/models/config_loader_error.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/domain/services/hdl_language_detector.dart';

/// Validates per-test simulator/language compatibility after the
/// config loader has flattened defaults / suite / test inheritance.
///
/// For each [TestSpec]:
///
/// 1. Resolves every source file's [HdlLanguage] — either via the
///    test's `sourceLanguages` map (explicit override) or via
///    [HdlLanguageDetector] (extension-driven fallback).
/// 2. Looks up the configured simulator's
///    [SimulatorCapabilities.supportedLanguages].
/// 3. Compares: any source whose language is not in the simulator's
///    supported set produces a structured [ConfigLoaderError] with a
///    clear, actionable message naming the offending file, the
///    detected language, the simulator id, and the list of simulators
///    that *could* handle that language.
///
/// Cocotb is a special case. Its declared `supportedLanguages` is
/// just `python` because the driver wraps an underlying HDL simulator
/// — accepting HDL sources alongside a Python testbench is the normal
/// flow, not an error. Cocotb's effective language coverage is the
/// union of its possible backends (`icarus` / `verilator` / `ghdl`),
/// which is `verilog ∪ systemVerilog ∪ vhdl`. The validator therefore
/// admits any HDL source under Cocotb.
class MixedLanguageValidator {
  /// Creates a [MixedLanguageValidator] with the supplied simulator
  /// language catalog. The map's keys are simulator ids; values are
  /// the set of [HdlLanguage]s that simulator can handle natively.
  const MixedLanguageValidator({
    required this.simulatorLanguages,
    this.detector = const HdlLanguageDetector(),
  });

  /// Simulator id → supported HDL language set. The validator
  /// special-cases Cocotb in [validate]; other ids are looked up here
  /// verbatim. Public so tests can introspect.
  final Map<String, Set<HdlLanguage>> simulatorLanguages;

  /// Extension-driven language detector. Public so tests can inject a
  /// stub.
  final HdlLanguageDetector detector;

  /// Simulator id for Cocotb. Its language compatibility is checked
  /// against the union of underlying-simulator languages rather than
  /// its declared `python`-only `supportedLanguages` set.
  static const String cocotbId = 'cocotb';

  /// The union of HDL languages Cocotb's three open-core backends
  /// (Icarus, Verilator, GHDL) can host. Used by the Cocotb-special
  /// case in [validate].
  static const Set<HdlLanguage> cocotbEffectiveLanguages = {
    HdlLanguage.verilog,
    HdlLanguage.systemVerilog,
    HdlLanguage.vhdl,
    HdlLanguage.python,
  };

  /// Validates every test in [tests] against its configured simulator.
  ///
  /// Returns an empty list when every test is compatible. Otherwise
  /// returns one [ConfigLoaderError] per offending (test, source)
  /// combination so the user can fix all incompatibilities in one
  /// pass.
  ///
  /// [configFilePath] is plumbed onto the resulting errors so the CLI
  /// can produce `path:line:col`-style diagnostics. The mixed-language
  /// check runs *after* YAML parsing finishes, so it never has a
  /// source span — the path-only form of [ConfigLoaderError] is the
  /// best we can do here.
  List<ConfigLoaderError> validate({
    required Iterable<TestSpec> tests,
    required String configFilePath,
  }) {
    final errors = <ConfigLoaderError>[];
    for (final test in tests) {
      final supportedSet = _effectiveSupported(test.simulatorId);
      if (supportedSet == null) {
        // Unknown simulator. Don't fire a mixed-language error here —
        // a separate validator (or the scheduler at run time) will
        // report the unknown id.
        continue;
      }
      for (final source in test.sources) {
        final declared = test.sourceLanguages[source];
        final detected = declared ?? detector.detect(source);
        if (detected == null) {
          // Unknown extension and no explicit override — assume the
          // user knows what they're doing; the simulator will reject
          // unsupported files at compile time. Mixed-language
          // validation isn't a file-extension whitelist.
          continue;
        }
        if (supportedSet.contains(detected)) continue;
        errors.add(
          ConfigLoaderError.generic(
            path: configFilePath,
            message:
                'Test `${test.id}` requires ${_describe(detected)} support '
                '(file `$source`); the configured simulator '
                '`${test.simulatorId}` only supports '
                '${_describeSet(supportedSet)}. '
                'Switch the simulator to ${_suggestSimulators(detected)} '
                'or remove the file.',
          ),
        );
      }
    }
    return errors;
  }

  Set<HdlLanguage>? _effectiveSupported(String simulatorId) {
    if (simulatorId == cocotbId) {
      // Always admit Python testbenches plus HDL sources for whichever
      // backend Cocotb is wrapping.
      return cocotbEffectiveLanguages;
    }
    return simulatorLanguages[simulatorId];
  }

  String _describe(HdlLanguage lang) {
    switch (lang) {
      case HdlLanguage.verilog:
        return 'Verilog';
      case HdlLanguage.systemVerilog:
        return 'SystemVerilog';
      case HdlLanguage.vhdl:
        return 'VHDL';
      case HdlLanguage.python:
        return 'Python (Cocotb)';
      case HdlLanguage.mixed:
        return 'mixed-language';
    }
  }

  String _describeSet(Set<HdlLanguage> langs) {
    if (langs.isEmpty) return 'no languages';
    final sorted = langs.toList()..sort((a, b) => a.index.compareTo(b.index));
    return sorted.map(_describe).join(' / ');
  }

  /// Returns a comma-separated list of simulator ids known to support
  /// [lang]. Always includes `cocotb` when [lang] is one of Verilog /
  /// SystemVerilog / VHDL because Cocotb wraps any of those.
  String _suggestSimulators(HdlLanguage lang) {
    final out = <String>[];
    for (final entry in simulatorLanguages.entries) {
      if (entry.value.contains(lang)) {
        out.add(entry.key);
      }
    }
    if (lang == HdlLanguage.verilog ||
        lang == HdlLanguage.systemVerilog ||
        lang == HdlLanguage.vhdl) {
      if (!out.contains(cocotbId)) out.add(cocotbId);
    }
    if (out.isEmpty) return 'a different simulator';
    out.sort();
    if (out.length == 1) return '`${out.single}`';
    if (out.length == 2) return '`${out.first}` or `${out.last}`';
    final last = out.removeLast();
    return '${out.map((s) => '`$s`').join(', ')}, or `$last`';
  }
}
