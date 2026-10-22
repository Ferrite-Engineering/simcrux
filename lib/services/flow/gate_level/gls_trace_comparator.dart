// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

/// Bounds on one port dump: a hostile or runaway VCD cannot exhaust memory.
@immutable
class GlsVcdLimits {
  /// Creates limits.
  const GlsVcdLimits({
    this.maxBytes = 256 * 1024 * 1024,
    this.maxSamples = 4000000,
    this.maxVariables = 4096,
    this.maxWidth = 65536,
  });

  /// The headless binary's limits, and the app's: the dump is read once, in
  /// full, and one port dump of a long simulation is a few megabytes.
  static const GlsVcdLimits standard = GlsVcdLimits();

  /// The most bytes read from one file.
  final int maxBytes;

  /// The most clock edges sampled.
  final int maxSamples;

  /// The most variables kept from the port scope.
  final int maxVariables;

  /// The widest vector kept.
  final int maxWidth;
}

/// Why a port dump could not be read.
enum GlsVcdProblem {
  /// The file cannot be opened or is not a VCD.
  unreadable,

  /// The file is over [GlsVcdLimits.maxBytes], or holds more samples or
  /// variables than the limits allow.
  tooLarge,

  /// The port scope or the clock is not in the file.
  scopeMissing,
}

/// A port dump that could not be read.
class GlsVcdException implements Exception {
  /// Creates the exception.
  const GlsVcdException(this.problem, this.message);

  /// What went wrong.
  final GlsVcdProblem problem;

  /// A fixed description that never repeats a path or a signal name.
  final String message;

  @override
  String toString() => 'GlsVcdException(${problem.name}): $message';
}

/// The DUT's top-level port values, one row per rising clock edge.
///
/// Each value is the one the port held **immediately before** the edge, never
/// at the edge's own timestamp: the RTL's registers change in that timestep,
/// and `UNIT_DELAY=#1` gates change one unit later, so a sample at the edge
/// would compare two designs at different moments.
@immutable
class GlsPortTrace {
  /// Creates a trace.
  const GlsPortTrace({
    required this.ports,
    required this.widths,
    required this.timesPs,
    required this.samples,
  });

  /// The port names that appear in the dump, in first-seen order.
  final List<String> ports;

  /// The width of each port in bits, parallel to [ports].
  final List<int> widths;

  /// The time of each sampled edge in picoseconds.
  final List<int> timesPs;

  /// `samples[k][i]` is the value of `ports[i]` before edge `k`, most
  /// significant bit first, each bit one of `0 1 x z`.
  final List<List<String>> samples;
}

/// How a differing bit is classified.
enum GlsDifferenceKind {
  /// The RTL bit is X or Z and the gate bit is 0 or 1: the four-state RTL
  /// left a value open that synthesis closed (`x * 0`, an output nothing
  /// assigns, a `full_case` mux with an unknown select).
  xAsymmetry,

  /// Both bits are known and unequal, or the gate bit is X or Z where the RTL
  /// bit is known: netlist behaviour, never noise.
  real,
}

/// One port at one sample where the two runs differ.
@immutable
class GlsDifference {
  /// Creates a difference.
  const GlsDifference({
    required this.sample,
    required this.timePs,
    required this.port,
    required this.rtl,
    required this.gate,
    required this.kind,
  });

  /// The zero-based edge index.
  final int sample;

  /// The edge's time in picoseconds.
  final int timePs;

  /// The port's name.
  final String port;

  /// The RTL value, most significant bit first.
  final String rtl;

  /// The gate value, most significant bit first.
  final String gate;

  /// [GlsDifferenceKind.real] when any bit is real, else X-asymmetry.
  final GlsDifferenceKind kind;
}

/// The counts for one port.
@immutable
class GlsPortCounts {
  /// Creates counts.
  const GlsPortCounts({this.real = 0, this.xAsymmetry = 0});

  /// Samples where this port had a real difference.
  final int real;

  /// Samples where this port had only X-asymmetry.
  final int xAsymmetry;
}

/// What the comparison of one test's RTL and gate port dumps found.
///
/// A difference is counted per **port per sample**: one port that differs at
/// one clock edge is one difference, however many of its bits differ, and a
/// port with a real bit and an X-asymmetric bit at the same edge counts as
/// real. The bit and sample counts are kept for a triage view.
@immutable
class GlsComparison {
  /// Creates a comparison.
  const GlsComparison({
    required this.samplesCompared,
    required this.samplesRtl,
    required this.samplesGate,
    required this.realDiffs,
    required this.xDiffs,
    required this.realBits,
    required this.xBits,
    required this.realSamples,
    required this.xSamples,
    required this.firstRealPs,
    required this.firstXPs,
    required this.perPort,
    required this.portsCompared,
    required this.portsNotDumped,
    required this.sampleTimeMismatches,
    required this.listed,
  });

  /// Edges compared: the shorter of the two runs.
  final int samplesCompared;

  /// Edges the RTL dump holds.
  final int samplesRtl;

  /// Edges the gate dump holds.
  final int samplesGate;

  /// Port-samples with a real difference.
  final int realDiffs;

  /// Port-samples with only X-asymmetry.
  final int xDiffs;

  /// Differing bits that are real.
  final int realBits;

  /// Differing bits that are X-asymmetry.
  final int xBits;

  /// Samples with at least one real difference.
  final int realSamples;

  /// Samples with at least one X-asymmetry and no real difference.
  final int xSamples;

  /// The time in picoseconds of the first sample with a real difference.
  final int? firstRealPs;

  /// The time in picoseconds of the first sample with X-asymmetry.
  final int? firstXPs;

  /// Counts by port, for ports that differ.
  final Map<String, GlsPortCounts> perPort;

  /// The ports compared: those dumped on both sides.
  final List<String> portsCompared;

  /// Ports the list asked for that one side did not dump.
  final List<String> portsNotDumped;

  /// Edges where the two runs' edge times differ.
  final int sampleTimeMismatches;

  /// The first differences, up to the `listLimit` the comparison was asked
  /// for (none by default), in sample then port order.
  final List<GlsDifference> listed;

  /// The time in picoseconds of the first difference: the first real one,
  /// else the first X-asymmetry, else null.
  int? get firstDiffPs => firstRealPs ?? firstXPs;
}

/// Reads the DUT's top-level ports out of the VCDs of an RTL run and a
/// gate-level run, samples them before each rising clock edge, and
/// classifies what differs.
///
/// **Pure Dart and bounded.** The headless binary cannot import WaveCrux's
/// Rust reader, and a port dump is the only thing needed: the reader keeps
/// only the variables of one scope whose names are in the port list, reads the
/// file as a stream, and never builds the signal table of the whole
/// simulation. A value change for an identifier outside that scope is
/// dropped. The app runs [compareFiles] on a background isolate; the file and
/// sample limits ([GlsVcdLimits]) hold everywhere.
///
/// **One simulator.** The two dumps must come from the same simulator; the
/// runner builds both from one value of `glsSimulatorIdFor`, and nothing here
/// can tell otherwise.
abstract final class GlsTraceComparator {
  /// Reads [path]: the variables of [scope] named in [ports], sampled
  /// before each rising edge of [clock].
  ///
  /// [scope] is dotted (`tb.uut`); a dump whose top scope is wrapped (`TOP`)
  /// matches too. Throws [GlsVcdException].
  static Future<GlsPortTrace> readTrace(
    String path, {
    required String scope,
    required Set<String> ports,
    required String clock,
    GlsVcdLimits limits = GlsVcdLimits.standard,
  }) async {
    final file = File(path);
    final int length;
    try {
      length = await file.length();
    } on FileSystemException {
      throw const GlsVcdException(
        GlsVcdProblem.unreadable,
        'the port dump cannot be opened',
      );
    }
    if (length > limits.maxBytes) {
      throw const GlsVcdException(
        GlsVcdProblem.tooLarge,
        'the port dump is over the size limit',
      );
    }
    final reader = _VcdPortReader(
      scope: scope,
      ports: ports,
      clock: clock,
      limits: limits,
    );
    try {
      await file
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach(reader.add);
    } on FileSystemException {
      throw const GlsVcdException(
        GlsVcdProblem.unreadable,
        'the port dump cannot be read',
      );
    } on FormatException {
      throw const GlsVcdException(
        GlsVcdProblem.unreadable,
        'the port dump is not text',
      );
    }
    return reader.finish();
  }

  /// Compares [rtl] with [gate], sample by sample.
  ///
  /// Sample `k` of one is compared with sample `k` of the other; ports are
  /// matched by name. [listLimit] is how many [GlsDifference]s to keep
  /// (zero keeps none: the counts need none).
  static GlsComparison compare(
    GlsPortTrace rtl,
    GlsPortTrace gate, {
    int listLimit = 0,
  }) {
    final gateIndex = <String, int>{
      for (var i = 0; i < gate.ports.length; i++) gate.ports[i]: i,
    };
    final pairs = <(int rtl, int gate)>[];
    final compared = <String>[];
    final missing = <String>{};
    for (var i = 0; i < rtl.ports.length; i++) {
      final g = gateIndex[rtl.ports[i]];
      if (g == null) {
        missing.add(rtl.ports[i]);
      } else {
        pairs.add((i, g));
        compared.add(rtl.ports[i]);
      }
    }
    for (final name in gate.ports) {
      if (!rtl.ports.contains(name)) missing.add(name);
    }

    final n = rtl.samples.length < gate.samples.length
        ? rtl.samples.length
        : gate.samples.length;
    var realDiffs = 0;
    var xDiffs = 0;
    var realBits = 0;
    var xBits = 0;
    var realSamples = 0;
    var xSamples = 0;
    var timeMismatches = 0;
    int? firstReal;
    int? firstX;
    final perPort = <String, ({int real, int x})>{};
    final listed = <GlsDifference>[];

    for (var k = 0; k < n; k++) {
      if (rtl.timesPs[k] != gate.timesPs[k]) timeMismatches++;
      final rtlRow = rtl.samples[k];
      final gateRow = gate.samples[k];
      var sampleReal = false;
      var sampleX = false;
      for (final (r, g) in pairs) {
        final a = rtlRow[r];
        final b = gateRow[g];
        if (identical(a, b) || a == b) continue;
        var portReal = false;
        var portX = false;
        final bits = a.length < b.length ? a.length : b.length;
        for (var bit = 0; bit < bits; bit++) {
          final x = a.codeUnitAt(bit);
          final y = b.codeUnitAt(bit);
          if (x == y) continue;
          final rtlKnown = x == 0x30 || x == 0x31;
          final gateKnown = y == 0x30 || y == 0x31;
          if (!rtlKnown && !gateKnown) continue;
          if (rtlKnown) {
            realBits++;
            portReal = true;
          } else {
            xBits++;
            portX = true;
          }
        }
        if (!portReal && !portX) continue;
        final name = rtl.ports[r];
        final previous = perPort[name] ?? (real: 0, x: 0);
        if (portReal) {
          realDiffs++;
          sampleReal = true;
          perPort[name] = (real: previous.real + 1, x: previous.x);
        } else {
          xDiffs++;
          sampleX = true;
          perPort[name] = (real: previous.real, x: previous.x + 1);
        }
        if (listed.length < listLimit) {
          listed.add(
            GlsDifference(
              sample: k,
              timePs: rtl.timesPs[k],
              port: name,
              rtl: a,
              gate: b,
              kind: portReal
                  ? GlsDifferenceKind.real
                  : GlsDifferenceKind.xAsymmetry,
            ),
          );
        }
      }
      if (sampleReal) {
        realSamples++;
        firstReal ??= rtl.timesPs[k];
      } else if (sampleX) {
        xSamples++;
      }
      if (sampleX) firstX ??= rtl.timesPs[k];
    }
    return GlsComparison(
      samplesCompared: n,
      samplesRtl: rtl.samples.length,
      samplesGate: gate.samples.length,
      realDiffs: realDiffs,
      xDiffs: xDiffs,
      realBits: realBits,
      xBits: xBits,
      realSamples: realSamples,
      xSamples: xSamples,
      firstRealPs: firstReal,
      firstXPs: firstX,
      perPort: <String, GlsPortCounts>{
        for (final e in perPort.entries)
          e.key: GlsPortCounts(real: e.value.real, xAsymmetry: e.value.x),
      },
      portsCompared: compared,
      portsNotDumped: (missing.toList()..sort()),
      sampleTimeMismatches: timeMismatches,
      listed: listed,
    );
  }

  /// Reads both dumps and compares them. Safe to run on a background
  /// isolate: it takes and returns plain values.
  static Future<GlsComparison> compareFiles({
    required String rtlPath,
    required String gatePath,
    required String scope,
    required Set<String> ports,
    required String clock,
    GlsVcdLimits limits = GlsVcdLimits.standard,
    int listLimit = 0,
  }) async {
    final rtl = await readTrace(
      rtlPath,
      scope: scope,
      ports: ports,
      clock: clock,
      limits: limits,
    );
    final gate = await readTrace(
      gatePath,
      scope: scope,
      ports: ports,
      clock: clock,
      limits: limits,
    );
    return compare(rtl, gate, listLimit: listLimit);
  }
}

class _Var {
  _Var(this.name, this.width, this.value);

  final String name;
  final int width;
  String value;
}

/// The streaming parser behind [GlsTraceComparator.readTrace].
class _VcdPortReader {
  _VcdPortReader({
    required this.scope,
    required this.ports,
    required this.clock,
    required this.limits,
  });

  final String scope;
  final Set<String> ports;
  final String clock;
  final GlsVcdLimits limits;

  final List<_Var> _vars = <_Var>[];
  final Map<String, List<int>> _byCode = <String, List<int>>{};
  final List<String> _stack = <String>[];
  final Map<int, String> _pending = <int, String>{};
  final List<int> _times = <int>[];
  final List<List<String>> _samples = <List<String>>[];
  final List<int> _clockVars = <int>[];

  bool _inHeader = true;
  bool _inTimescale = false;
  final List<String> _timescaleTokens = <String>[];
  double _unitPs = 1;
  int _time = 0;
  bool _sawScope = false;

  void add(String raw) {
    final line = raw.trim();
    if (line.isEmpty) return;
    if (_inHeader) {
      _header(line);
      return;
    }
    final head = line.codeUnitAt(0);
    if (head == 0x23) {
      // `#<time>`: what changed at the previous time is now complete.
      _flush();
      final t = int.tryParse(line.substring(1));
      if (t != null) _time = t;
    } else if (head == 0x62 || head == 0x42) {
      // `b<bits> <code>`
      final space = line.indexOf(' ');
      if (space < 0) return;
      final indexes = _byCode[line.substring(space + 1).trim()];
      if (indexes == null) return;
      final bits = line.substring(1, space).toLowerCase();
      for (final i in indexes) {
        _pending[i] = _extend(bits, _vars[i].width);
      }
    } else if (head == 0x30 ||
        head == 0x31 ||
        head == 0x78 ||
        head == 0x58 ||
        head == 0x7a ||
        head == 0x5a) {
      final indexes = _byCode[line.substring(1)];
      if (indexes == null) return;
      final bit = String.fromCharCode(head).toLowerCase();
      for (final i in indexes) {
        _pending[i] = bit;
      }
    }
  }

  void _header(String line) {
    if (_inTimescale) {
      _timescaleTokens.addAll(line.split(RegExp(r'\s+')));
      if (line.contains(r'$end')) _finishTimescale();
      return;
    }
    if (line.startsWith(r'$timescale')) {
      _timescaleTokens.addAll(
        line.substring(r'$timescale'.length).trim().split(RegExp(r'\s+')),
      );
      if (line.contains(r'$end')) {
        _finishTimescale();
      } else {
        _inTimescale = true;
      }
    } else if (line.startsWith(r'$scope')) {
      final parts = line.split(RegExp(r'\s+'));
      _stack.add(parts.length > 2 ? parts[2] : '');
    } else if (line.startsWith(r'$upscope')) {
      if (_stack.isNotEmpty) _stack.removeLast();
    } else if (line.startsWith(r'$var')) {
      _var(line);
    } else if (line.startsWith(r'$enddefinitions')) {
      _inHeader = false;
    }
  }

  void _finishTimescale() {
    _inTimescale = false;
    final text = _timescaleTokens
        .where((t) => t != r'$end')
        .join()
        .toLowerCase();
    _timescaleTokens.clear();
    final match = RegExp(r'^(\d+)(fs|ps|ns|us|ms|s)$').firstMatch(text);
    if (match == null) return;
    final scale = double.parse(match.group(1)!);
    _unitPs =
        scale *
        switch (match.group(2)) {
          'fs' => 0.001,
          'ps' => 1.0,
          'ns' => 1000.0,
          'us' => 1000000.0,
          'ms' => 1000000000.0,
          _ => 1000000000000.0,
        };
  }

  bool _inScope() {
    final joined = _stack.join('.');
    return joined == scope || joined.endsWith('.$scope');
  }

  void _var(String line) {
    final parts = line.split(RegExp(r'\s+'));
    // $var <type> <width> <code> <name> [range] $end
    if (parts.length < 6) return;
    final type = parts[1];
    if (type == 'real' || type == 'event' || type == 'string') return;
    final width = int.tryParse(parts[2]);
    final code = parts[3];
    final name = parts[4];
    if (width == null || width < 1) return;
    if (!_inScope() || !ports.contains(name)) return;
    _sawScope = true;
    if (width > limits.maxWidth) {
      throw const GlsVcdException(
        GlsVcdProblem.tooLarge,
        'a port in the dump is wider than the limit',
      );
    }
    if (_vars.length >= limits.maxVariables) {
      throw const GlsVcdException(
        GlsVcdProblem.tooLarge,
        'the dump holds more ports than the limit',
      );
    }
    final index = _vars.length;
    _vars.add(_Var(name, width, 'x' * width));
    (_byCode[code] ??= <int>[]).add(index);
    if (name == clock) _clockVars.add(index);
  }

  /// A vector change shorter than its variable is extended on the left with
  /// 0, or with x or z when its leftmost bit is one (the VCD rule).
  static String _extend(String bits, int width) {
    if (bits.length >= width) {
      return bits.length == width ? bits : bits.substring(bits.length - width);
    }
    final pad = bits.isNotEmpty && (bits[0] == 'x' || bits[0] == 'z')
        ? bits[0]
        : '0';
    return pad * (width - bits.length) + bits;
  }

  void _flush() {
    if (_pending.isEmpty) return;
    for (final c in _clockVars) {
      final next = _pending[c];
      if (next == '1' && _vars[c].value == '0') {
        if (_samples.length >= limits.maxSamples) {
          throw const GlsVcdException(
            GlsVcdProblem.tooLarge,
            'the dump holds more clock edges than the limit',
          );
        }
        _times.add((_time * _unitPs).round());
        _samples.add(<String>[for (final v in _vars) v.value]);
        break;
      }
    }
    _pending.forEach((i, value) => _vars[i].value = value);
    _pending.clear();
  }

  GlsPortTrace finish() {
    _flush();
    if (_inHeader || !_sawScope || _clockVars.isEmpty) {
      throw const GlsVcdException(
        GlsVcdProblem.scopeMissing,
        'the port scope or the clock is not in the dump',
      );
    }
    return GlsPortTrace(
      ports: <String>[for (final v in _vars) v.name],
      widths: <int>[for (final v in _vars) v.width],
      timesPs: _times,
      samples: _samples,
    );
  }
}
