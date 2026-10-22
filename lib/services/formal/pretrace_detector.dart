// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_netlist/crux_netlist.dart';
import 'package:meta/meta.dart';

/// One formal cell of an elaborated design and the deepest `$past` chain
/// feeding it.
@immutable
class FormalCellExposure {
  /// Creates an exposure.
  const FormalCellExposure({
    required this.kind,
    required this.location,
    required this.pastDepth,
    this.reads = const <String>[],
    this.neverEnabled = false,
    this.disabledBy = const <String>[],
  });

  /// `assert`, `assume`, `cover`, `live` or `fair`.
  final String kind;

  /// The cell's `src` attribute (`fifo.sv:47.3-47.92`), the spelling `sby`
  /// uses for the property's location; empty when the cell has none.
  final String location;

  /// The longest chain of `$past` registers between a design signal and
  /// the cell's inputs; 0 when no `$past` feeds it.
  final int pastDepth;

  /// The design signals the property reads, nearest first: every named net
  /// on the combinational paths into the cell's `A` input, then its `EN`
  /// input, up to and including the register outputs where those paths
  /// start. A signal of the design's top module is written rooted at it
  /// (`handshake.f_wait`); one of another module by its own name, since a
  /// module can be instantiated more than once. At most
  /// [PretraceDetector.kMaxReads].
  final List<String> reads;

  /// Whether this check can never be enabled: its enable (an immediate
  /// check's `if`, a concurrent one's `disable iff`) is constant false, or
  /// false whenever the design's unconditional assumptions hold. An
  /// assertion like that passes without ever being checked. Decided only
  /// through the few cell types [PretraceDetector] evaluates; anything else
  /// is "may be enabled", never a guess.
  final bool neverEnabled;

  /// The `src` of each unconditional assumption that holds the enable
  /// false, when [neverEnabled] and the enable is not a constant.
  final List<String> disabledBy;

  @override
  bool operator ==(Object other) =>
      other is FormalCellExposure &&
      other.kind == kind &&
      other.location == location &&
      other.pastDepth == pastDepth &&
      other.reads.join('\n') == reads.join('\n') &&
      other.neverEnabled == neverEnabled &&
      other.disabledBy.join('\n') == disabledBy.join('\n');

  @override
  int get hashCode => Object.hash(
    kind,
    location,
    pastDepth,
    Object.hashAll(reads),
    neverEnabled,
    Object.hashAll(disabledBy),
  );

  @override
  String toString() => 'FormalCellExposure($kind @ $location, $pastDepth)';
}

/// What the static analysis of an elaborated design found.
@immutable
class FormalDesignFacts {
  /// Creates the facts.
  const FormalDesignFacts({required this.cells});

  /// Every formal cell, in module and cell order.
  final List<FormalCellExposure> cells;

  /// How many formal cells of [kind] the design holds.
  int count(String kind) => cells.where((c) => c.kind == kind).length;

  /// The exposure of the cell at [location] (exact `src` match, else the
  /// first cell on the same file and line), or null.
  FormalCellExposure? at(String location) {
    for (final cell in cells) {
      if (cell.location == location) return cell;
    }
    final line = _fileLine(location);
    if (line == null) return null;
    for (final cell in cells) {
      if (_fileLine(cell.location) == line) return cell;
    }
    return null;
  }

  static final RegExp _fileLinePattern = RegExp(r'^(.*?):(\d+)');

  static String? _fileLine(String location) {
    final match = _fileLinePattern.firstMatch(location);
    if (match == null) return null;
    final file = match.group(1)!.replaceAll(r'\', '/');
    final slash = file.lastIndexOf('/');
    return '${slash < 0 ? file : file.substring(slash + 1)}:${match.group(2)}';
  }
}

/// Finds the `$past` registers that feed each formal cell of a design, and
/// how deep the chain is, from Yosys's `write_json` of the design `sby`
/// elaborated (`model/design.il`).
///
/// ## Why this matters
///
/// `$past(x, N)` is a chain of N registers. Before the trace has run N
/// steps the chain still holds its initial value, which nothing
/// constrains: a cover can be "reached" and an assertion can "fail" on a
/// value the design never had. The fixture corpus measures it
/// (`fifo_slang` `c_drain` is reached at step 2 on a trace where `full` is
/// never 1), and nothing in the open stack warns.
///
/// ## How a `$past` register is recognised
///
/// Both open frontends name what they build for `$past` (and for `$rose`,
/// `$fell`, `$stable`, `$changed`, which are one `$past` deep):
/// yosys-slang names the register cell `$past$<n>` and its output net
/// `$$past$<n>`; the built-in frontend names the output net
/// `$past$<file>:<line>$<n>$<i>` and leaves the cell anonymous
/// (`$procdff$<n>`). A flip-flop is a `$past` register when its name or
/// any net carrying its output says so. Design registers, which the user
/// can constrain (reset, `initial assume`), are never counted.
///
/// ## Depth
///
/// The depth of a `$past` register is one plus the deepest `$past`
/// register reachable backwards from its data input through combinational
/// cells only; a cell's exposure is the deepest `$past` register reachable
/// backwards from its `A` and `EN` inputs the same way. Every module is
/// analysed on its own: a `$past` chain never crosses a module boundary.
///
/// ## Enables no assumption lets through
///
/// The same pass records, for each assertion, whether its enable can never
/// be true ([FormalCellExposure.neverEnabled]): a constant-false enable, or
/// one the module's unconditional assumptions hold false (`assume (rst)`
/// with `disable iff (rst)`, measured identical on both open frontends).
/// The enable is evaluated through `$not`, `$logic_not`, one-bit `$and`,
/// `$or`, `$reduce_*` and `$mux` only, and an assumption counts only on the
/// assertion's own trigger; anything else reads as "may be enabled".
class PretraceDetector {
  /// Creates a detector.
  const PretraceDetector();

  /// Yosys's formal cell types: the legacy per-kind cells and `$check`,
  /// whose `FLAVOR` parameter carries the kind.
  static const Map<String, String> _legacyKinds = <String, String>{
    r'$assert': 'assert',
    r'$assume': 'assume',
    r'$cover': 'cover',
    r'$live': 'live',
    r'$fair': 'fair',
  };

  static final RegExp _pastName = RegExp(r'^\$+past\$');

  /// The most signals [FormalCellExposure.reads] lists for one property.
  static const int kMaxReads = 16;

  /// Every formal cell of [model] with its `$past` exposure.
  FormalDesignFacts analyse(NetlistModel model) {
    final top = model.topModule?.name;
    final cells = <FormalCellExposure>[];
    for (final module in model.modules.values) {
      cells.addAll(_analyseModule(module, rooted: module.name == top));
    }
    return FormalDesignFacts(
      cells: List<FormalCellExposure>.unmodifiable(cells),
    );
  }

  List<FormalCellExposure> _analyseModule(
    Module module, {
    required bool rooted,
  }) {
    // Which cell drives each net bit.
    final driver = <int, Cell>{};
    for (final cell in module.cells.values) {
      cell.connections.forEach((port, bits) {
        if (cell.portDirections[port] != PortDirection.output) return;
        for (final bit in bits) {
          if (bit is NetBit) driver[bit.netId] = cell;
        }
      });
    }
    final pastBits = <int>{
      for (final net in module.nets.values)
        if (_pastName.hasMatch(net.name))
          for (final bit in net.bits)
            if (bit is NetBit) bit.netId,
    };
    bool isPast(Cell cell) {
      if (!_isFlipFlop(cell)) return false;
      if (_pastName.hasMatch(cell.name)) return true;
      final q = cell.connections['Q'] ?? const <BitRef>[];
      return q.any((b) => b is NetBit && pastBits.contains(b.netId));
    }

    /// The `$past` registers reachable backwards from [bits] through
    /// combinational cells.
    Set<Cell> pastFeeding(Iterable<BitRef> bits) {
      final found = <Cell>{};
      final seen = <int>{};
      final queue = <int>[
        for (final b in bits)
          if (b is NetBit) b.netId,
      ];
      while (queue.isNotEmpty) {
        final bit = queue.removeLast();
        if (!seen.add(bit)) continue;
        final cell = driver[bit];
        if (cell == null) continue;
        if (_isFlipFlop(cell)) {
          if (isPast(cell)) found.add(cell);
          continue;
        }
        if (_isState(cell)) continue;
        cell.connections.forEach((port, portBits) {
          if (cell.portDirections[port] == PortDirection.output) return;
          for (final b in portBits) {
            if (b is NetBit) queue.add(b.netId);
          }
        });
      }
      return found;
    }

    final depthMemo = <Cell, int>{};
    int depthOf(Cell cell, Set<Cell> visiting) {
      final memo = depthMemo[cell];
      if (memo != null) return memo;
      // A loop of `$past` registers cannot come from `$past`, but a
      // malformed design must not recurse forever.
      if (!visiting.add(cell)) return 1;
      var deepest = 0;
      for (final upstream in pastFeeding(
        cell.connections['D'] ?? const <BitRef>[],
      )) {
        final d = depthOf(upstream, visiting);
        if (d > deepest) deepest = d;
      }
      visiting.remove(cell);
      return depthMemo[cell] = deepest + 1;
    }

    // The user's names for each net bit, in declaration order: what a
    // property reads is said in the names the design gave its signals.
    final namesOf = <int, List<String>>{};
    for (final net in module.nets.values) {
      final name = net.name;
      if (net.hideName ||
          name.isEmpty ||
          name.startsWith(r'$') ||
          name.contains(',') ||
          _pastName.hasMatch(name)) {
        continue;
      }
      for (final bit in net.bits) {
        if (bit is NetBit) (namesOf[bit.netId] ??= <String>[]).add(name);
      }
    }

    /// The named signals on the combinational paths into [bits], nearest
    /// first, stopping at (and including the outputs of) registers.
    List<String> readsOf(List<BitRef> bits) {
      final found = <String>[];
      final seen = <int>{};
      final queue = <int>[
        for (final b in bits)
          if (b is NetBit) b.netId,
      ];
      for (var i = 0; i < queue.length && found.length < kMaxReads; i++) {
        final bit = queue[i];
        if (!seen.add(bit)) continue;
        for (final name in namesOf[bit] ?? const <String>[]) {
          final shown = rooted ? '${module.name}.$name' : name;
          if (!found.contains(shown)) found.add(shown);
          if (found.length >= kMaxReads) break;
        }
        final cell = driver[bit];
        if (cell == null || _isState(cell)) continue;
        if (_isFlipFlop(cell)) {
          // A `$past` register is the property's own history of a design
          // signal, so the signal it samples is read too; a design register
          // is where the path starts.
          if (isPast(cell)) {
            for (final b in cell.connections['D'] ?? const <BitRef>[]) {
              if (b is NetBit && !seen.contains(b.netId)) queue.add(b.netId);
            }
          }
          continue;
        }
        cell.connections.forEach((port, portBits) {
          if (cell.portDirections[port] == PortDirection.output) return;
          for (final b in portBits) {
            if (b is NetBit && !seen.contains(b.netId)) queue.add(b.netId);
          }
        });
      }
      return List<String>.unmodifiable(found);
    }

    final pins = _assumptionPins(module, driver);

    final out = <FormalCellExposure>[];
    for (final cell in module.cells.values) {
      final kind = _formalKind(cell);
      if (kind == null) continue;
      final inputs = <BitRef>[
        ...?cell.connections['A'],
        ...?cell.connections['EN'],
      ];
      var deepest = 0;
      for (final past in pastFeeding(inputs)) {
        final d = depthOf(past, <Cell>{});
        if (d > deepest) deepest = d;
      }
      final enable = kind == 'assert'
          ? _neverEnabled(cell, driver, pins)
          : null;
      out.add(
        FormalCellExposure(
          kind: kind,
          location: cell.attributes['src'] ?? '',
          pastDepth: deepest,
          reads: readsOf(inputs),
          neverEnabled: enable != null,
          disabledBy: enable ?? const <String>[],
        ),
      );
    }
    return out;
  }

  /// The deepest a 1-bit enable is evaluated through combinational cells.
  static const int _kMaxEvalDepth = 16;

  /// The values the module's unconditional assumptions hold 1-bit nets at,
  /// each with the assumption's `src` and its trigger: an `assume` whose
  /// enable is the constant 1 and whose condition is a net (held 1), the
  /// negation of a net (held 0), or a conjunction of those.
  static Map<int, ({bool value, String src, String trigger})> _assumptionPins(
    Module module,
    Map<int, Cell> driver,
  ) {
    final pins = <int, ({bool value, String src, String trigger})>{};
    for (final cell in module.cells.values) {
      if (_formalKind(cell) != 'assume') continue;
      final en = cell.connections['EN'] ?? const <BitRef>[];
      final unconditional =
          en.isEmpty ||
          (en.length == 1 &&
              en.single is ConstantBit &&
              (en.single as ConstantBit).value == ConstantBitValue.one);
      final a = cell.connections['A'] ?? const <BitRef>[];
      if (!unconditional || a.length != 1) continue;
      final src = cell.attributes['src'] ?? '';
      final trigger = _triggerOf(cell);
      void pin(BitRef bit, int depth, {required bool value}) {
        if (bit is! NetBit || depth > 4) return;
        final from = driver[bit.netId];
        final type = from?.type;
        final ins = from == null ? null : _singleBitInputs(from);
        if ((type == r'$not' || type == r'$logic_not') &&
            ins != null &&
            ins.length == 1) {
          pin(ins.single, depth + 1, value: !value);
          return;
        }
        if (value &&
            (type == r'$and' || type == r'$logic_and') &&
            ins != null &&
            ins.length == 2) {
          for (final b in ins) {
            pin(b, depth + 1, value: true);
          }
          return;
        }
        pins.putIfAbsent(
          bit.netId,
          () => (value: value, src: src, trigger: trigger),
        );
      }

      pin(a.single, 0, value: true);
    }
    return pins;
  }

  /// The `src` of each assumption that holds [cell]'s enable false (empty
  /// for a constant-false enable), or null when it may be enabled.
  static List<String>? _neverEnabled(
    Cell cell,
    Map<int, Cell> driver,
    Map<int, ({bool value, String src, String trigger})> pins,
  ) {
    final en = cell.connections['EN'] ?? const <BitRef>[];
    if (en.length != 1) return null;
    final trigger = _triggerOf(cell);
    final used = <String>{};
    bool? eval(BitRef bit, int depth) {
      if (bit is ConstantBit) {
        return switch (bit.value) {
          ConstantBitValue.one => true,
          ConstantBitValue.zero => false,
          _ => null,
        };
      }
      if (bit is! NetBit || depth > _kMaxEvalDepth) return null;
      final pin = pins[bit.netId];
      // An assumption sampled on another trigger says nothing about the
      // values this check samples.
      if (pin != null && pin.trigger == trigger) {
        used.add(pin.src);
        return pin.value;
      }
      final from = driver[bit.netId];
      if (from == null) return null;
      final ins = _singleBitInputs(from);
      switch (from.type) {
        case r'$not' || r'$logic_not' when ins != null && ins.length == 1:
          final v = eval(ins.single, depth + 1);
          return v == null ? null : !v;
        case r'$and' || r'$logic_and' when ins != null && ins.length == 2:
          final a = eval(ins[0], depth + 1);
          final b = eval(ins[1], depth + 1);
          if (a == false || b == false) return false;
          return a == true && b == true ? true : null;
        case r'$or' || r'$logic_or' when ins != null && ins.length == 2:
          final a = eval(ins[0], depth + 1);
          final b = eval(ins[1], depth + 1);
          if (a == true || b == true) return true;
          return a == false && b == false ? false : null;
        case r'$reduce_and' || r'$reduce_or' || r'$reduce_bool'
            when ins != null && ins.length == 1:
          return eval(ins.single, depth + 1);
        case r'$mux':
          final a = from.connections['A'] ?? const <BitRef>[];
          final b = from.connections['B'] ?? const <BitRef>[];
          final s = from.connections['S'] ?? const <BitRef>[];
          if (a.length != 1 || b.length != 1 || s.length != 1) return null;
          final sel = eval(s.single, depth + 1);
          if (sel == true) return eval(b.single, depth + 1);
          if (sel == false) return eval(a.single, depth + 1);
          final va = eval(a.single, depth + 1);
          return va != null && va == eval(b.single, depth + 1) ? va : null;
      }
      return null;
    }

    if (eval(en.single, 0) != false) return null;
    return List<String>.unmodifiable(used.toList()..sort());
  }

  /// The trigger bits of a `$check` cell, or empty for a legacy cell
  /// (sampled every step).
  static String _triggerOf(Cell cell) =>
      (cell.connections['TRG'] ?? const <BitRef>[])
          .map((b) => '${b.toJson()}')
          .join(',');

  /// The input bits of a cell whose every input port is one bit wide, in
  /// port order, or null when one is wider.
  static List<BitRef>? _singleBitInputs(Cell cell) {
    final ins = <BitRef>[];
    for (final port in const <String>['A', 'B']) {
      final bits = cell.connections[port];
      if (bits == null) continue;
      if (cell.portDirections[port] == PortDirection.output) continue;
      if (bits.length != 1) return null;
      ins.add(bits.single);
    }
    return ins;
  }

  /// The formal kind of [cell], or null when it is not a formal cell.
  static String? _formalKind(Cell cell) {
    final legacy = _legacyKinds[cell.type];
    if (legacy != null) return legacy;
    if (cell.type != r'$check') return null;
    final flavor = cell.parameters['FLAVOR'];
    if (flavor == null) return null;
    return _decodeStringParameter(flavor);
  }

  /// A Yosys JSON string parameter: plain text, or (from older writers)
  /// the bits of its bytes.
  static String _decodeStringParameter(String value) {
    if (!RegExp(r'^[01]+$').hasMatch(value) || value.length % 8 != 0) {
      return value.trim();
    }
    final codes = <int>[
      for (var i = 0; i < value.length; i += 8)
        int.parse(value.substring(i, i + 8), radix: 2),
    ].where((c) => c != 0).toList();
    return String.fromCharCodes(codes).trim();
  }

  static bool _isFlipFlop(Cell cell) {
    final type = cell.type;
    return type == r'$ff' ||
        type == r'$dff' ||
        type == r'$dffe' ||
        type == r'$adff' ||
        type == r'$adffe' ||
        type == r'$sdff' ||
        type == r'$sdffe' ||
        type == r'$sdffce' ||
        type == r'$aldff' ||
        type == r'$aldffe' ||
        type == r'$dffsr' ||
        type == r'$dffsre' ||
        type == r'$dlatch' ||
        type.startsWith(r'$_DFF') ||
        type.startsWith(r'$_SDFF') ||
        type.startsWith(r'$_FF_');
  }

  /// Cells that hold state without being a flip-flop: memories. Never
  /// traversed.
  static bool _isState(Cell cell) => cell.type.startsWith(r'$mem');
}
