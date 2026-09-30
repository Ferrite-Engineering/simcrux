// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The counterexample corpus's traces are a **cross-product contract**.
///
/// The `riscv_formal` driver itself barely reads them: its tests only need a
/// VCD path that exists and survives the scheduler's cleanup sweep. The
/// consumer is WaveCrux, which resolves the CXP §9.9 `riscv.formal.trace_step`
/// coordinate against the file — and it cannot do that unless the trace
/// carries a real RVFI bundle on a measurable step lattice.
///
/// That gap is not hypothetical. An earlier revision of this corpus declared
/// three channels (`rvfi_valid`, `rvfi_insn`, `rvfi_rd_wdata`). Every test on
/// both sides passed, and the flagship "Open counterexample in WaveCrux"
/// hand-off opened the trace and landed nowhere, because WaveCrux requires
/// `rvfi_pc_rdata` before it will admit an RVFI bundle exists at all.
///
/// So the properties the *other product* depends on are asserted here, on the
/// committed bytes, next to the fixture that must hold them.
///
/// MUTATION: drop any channel from `tool/riscv_formal_traces.dart`, shorten
/// the counterexample below step 7, or move a value change off the lattice,
/// and this goes red — on the producer side, before the demo does.
void main() {
  const corpus = 'verification/fixtures/riscv_formal';

  /// The channels WaveCrux's `RvfiChannel` enum knows. Spelled out rather than
  /// imported from the generator: a test that reads its expectations out of
  /// the thing under test asserts nothing.
  const requiredChannels = <String>[
    'rvfi_valid',
    'rvfi_order',
    'rvfi_insn',
    'rvfi_trap',
    'rvfi_halt',
    'rvfi_intr',
    'rvfi_mode',
    'rvfi_ixl',
    'rvfi_rs1_addr',
    'rvfi_rs1_rdata',
    'rvfi_rs2_addr',
    'rvfi_rs2_rdata',
    'rvfi_rd_addr',
    'rvfi_rd_wdata',
    'rvfi_pc_rdata',
    'rvfi_pc_wdata',
    'rvfi_mem_addr',
    'rvfi_mem_rmask',
    'rvfi_mem_wmask',
    'rvfi_mem_rdata',
    'rvfi_mem_wdata',
  ];

  /// The three WaveCrux treats as load-bearing: without any one of them there
  /// is no retire stream, so there is nothing for a coordinate to address.
  const loadBearing = <String>['rvfi_valid', 'rvfi_insn', 'rvfi_pc_rdata'];

  for (final trace in _traces) {
    group(trace, () {
      final vcd = _Vcd.parse(File(p.join(corpus, trace)).readAsStringSync());

      test('declares the whole RVFI bundle', () {
        expect(
          vcd.widths.keys,
          containsAll(requiredChannels),
          reason:
              'a channel WaveCrux binds is missing; the Commit Inspector '
              'degrades or refuses to render',
        );
        for (final channel in loadBearing) {
          expect(
            vcd.widths.containsKey(channel),
            isTrue,
            reason:
                '$channel is required — without it WaveCrux reports the '
                'trace as carrying no RVFI bundle and declines every '
                'coordinate against it',
          );
        }
      });

      test(
        'every value change lands on a uniform step lattice from tick 0',
        () {
          // How a receiver recovers "step N" from a file that only has ticks:
          // the smallest gap between transitions is one step, and every
          // transition must then lie on that lattice. A trace that fails this
          // carries no step domain and the coordinate must be declined.
          expect(vcd.tickList.first, 0, reason: 'step 0 is the initial state');
          expect(vcd.tickList.length, greaterThan(1));
          var pitch = vcd.tickList[1] - vcd.tickList[0];
          for (var i = 2; i < vcd.tickList.length; i++) {
            final gap = vcd.tickList[i] - vcd.tickList[i - 1];
            if (gap > 0 && gap < pitch) pitch = gap;
          }
          expect(pitch, greaterThan(0));
          for (final tick in vcd.tickList) {
            expect(
              tick % pitch,
              0,
              reason: 'tick $tick is off the $pitch-tick step lattice',
            );
          }
        },
      );
    });
  }

  test('the counterexample reaches the step its log reports, and retires '
      'there', () {
    // The two facts are read from opposite ends of the corpus and must agree:
    // the depth comes from the production parser's golden, the retirement from
    // the committed trace. A coordinate addressing a step the trace does not
    // reach degrades to a decline; one addressing a step with no retirement
    // degrades to a bare cursor placement. The demo promises neither.
    const dir = '$corpus/insn_sub_counterexample';
    final golden =
        jsonDecode(File('$dir/expected.json').readAsStringSync())
            as Map<String, Object?>;
    final step = golden['depth_reached']! as int;
    expect(step, greaterThan(0), reason: 'step 0 is the reset state');

    final vcd = _Vcd.parse(File('$dir/engine_0/trace.vcd').readAsStringSync());
    final pitch = vcd.tickList[1] - vcd.tickList[0];
    final tick = step * pitch;
    expect(
      vcd.tickList.last,
      greaterThanOrEqualTo(tick),
      reason:
          'the trace stops before step $step, so the coordinate SimCrux '
          'emits addresses nothing',
    );
    expect(
      vcd.valueAt('rvfi_valid', tick),
      '1',
      reason:
          'no instruction retires at step $step, so the hand-off can only '
          'place a cursor — the card promises the violating instruction',
    );
  });

  test('the counterexample trace still matches WaveCrux’s pinned copy', () {
    // WaveCrux runs the consumer half of this hand-off end to end, against a
    // byte-identical copy of this file, in
    // `test/services/remote/cxp/riscv_counterexample_handoff_test.dart`. The
    // two repositories cannot run each other's tests, so the same digest is
    // asserted on both sides: regenerating here without re-copying there
    // turns that test red rather than leaving WaveCrux asserting against a
    // trace the demo no longer ships.
    expect(
      fixtureDigest(
        File(
          '$corpus/insn_sub_counterexample/engine_0/trace.vcd',
        ).readAsStringSync(),
      ),
      kCounterexampleTraceDigest,
      reason:
          'regenerated? copy it to '
          'wavecrux/test/fixtures/riscv_formal/'
          'insn_sub_counterexample_trace.vcd, and update the constant in '
          'both repositories',
    );
  });
}

/// FNV-1a of this corpus's `insn_sub_counterexample` trace, asserted here and
/// in WaveCrux against its copy.
const String kCounterexampleTraceDigest = '9e3350f6';

/// FNV-1a/32 over [text] with carriage returns dropped, so a CRLF checkout
/// digests the same as an LF one. Hand-rolled, and duplicated verbatim in
/// WaveCrux's test, because a cross-repo pin is not worth a dependency in
/// either package.
String fixtureDigest(String text) {
  var hash = 0x811C9DC5;
  for (final unit in text.codeUnits) {
    if (unit == 0x0D) continue;
    hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

const List<String> _traces = <String>[
  'insn_sub_counterexample/engine_0/trace.vcd',
  'cover_multi_trace/engine_0/trace0.vcd',
  'cover_multi_trace/engine_0/trace1.vcd',
];

/// The smallest VCD reader that can answer this file's questions: which
/// signals are declared, at which ticks anything changed, and what a signal
/// held at a tick.
class _Vcd {
  _Vcd(this.widths, this._changes, this.tickList);

  factory _Vcd.parse(String text) {
    final widths = <String, int>{};
    final idToName = <String, String>{};
    final changes = <String, List<(int, String)>>{};
    final ticks = <int>{};
    var time = 0;

    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith(r'$var')) {
        final parts = line.split(RegExp(r'\s+'));
        // $var wire <width> <id> <name> $end
        widths[parts[4]] = int.parse(parts[2]);
        idToName[parts[3]] = parts[4];
        continue;
      }
      if (line.startsWith(r'$')) continue;
      if (line.startsWith('#')) {
        time = int.parse(line.substring(1));
        continue;
      }
      final String id;
      final String value;
      if (line.startsWith('b')) {
        final space = line.indexOf(' ');
        value = line.substring(1, space);
        id = line.substring(space + 1).trim();
      } else {
        value = line.substring(0, 1);
        id = line.substring(1).trim();
      }
      final name = idToName[id];
      if (name == null) continue;
      changes.putIfAbsent(name, () => <(int, String)>[]).add((time, value));
      ticks.add(time);
    }
    return _Vcd(widths, changes, ticks.toList()..sort());
  }

  /// Declared bit width per signal name.
  final Map<String, int> widths;

  final Map<String, List<(int, String)>> _changes;

  /// Every tick at which at least one signal changed, ascending.
  final List<int> tickList;

  /// The value [name] held at [tick] — the last change at or before it.
  String? valueAt(String name, int tick) {
    String? held;
    for (final (at, value) in _changes[name] ?? const <(int, String)>[]) {
      if (at > tick) break;
      held = value;
    }
    return held;
  }
}
