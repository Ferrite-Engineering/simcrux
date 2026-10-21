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
  });

  /// `assert`, `assume`, `cover`, `live` or `fair`.
  final String kind;

  /// The cell's `src` attribute (`fifo.sv:47.3-47.92`), the spelling `sby`
  /// uses for the property's location; empty when the cell has none.
  final String location;

  /// The longest chain of `$past` registers between a design signal and
  /// the cell's inputs; 0 when no `$past` feeds it.
  final int pastDepth;

  @override
  bool operator ==(Object other) =>
      other is FormalCellExposure &&
      other.kind == kind &&
      other.location == location &&
      other.pastDepth == pastDepth;

  @override
  int get hashCode => Object.hash(kind, location, pastDepth);

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

  /// Every formal cell of [model] with its `$past` exposure.
  FormalDesignFacts analyse(NetlistModel model) {
    final cells = <FormalCellExposure>[];
    for (final module in model.modules.values) {
      cells.addAll(_analyseModule(module));
    }
    return FormalDesignFacts(
      cells: List<FormalCellExposure>.unmodifiable(cells),
    );
  }

  List<FormalCellExposure> _analyseModule(Module module) {
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
      out.add(
        FormalCellExposure(
          kind: kind,
          location: cell.attributes['src'] ?? '',
          pastDepth: deepest,
        ),
      );
    }
    return out;
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
