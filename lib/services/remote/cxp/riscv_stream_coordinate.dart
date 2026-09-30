// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_cxp/crux_cxp.dart';
import 'package:simcrux/domain/enums/riscv_formal_verdict.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/services/simulator/riscv_arch_driver.dart';
import 'package:simcrux/services/simulator/riscv_formal_driver.dart';
import 'package:simcrux/services/simulator/riscv_result_kind.dart';

/// Derives the CXP semantic stream coordinate (CXP §9.9,
/// https://edacrux.app/cxp#sec-9-9) a [TestResult] can
/// honestly carry into a cross-probe, or null when it cannot carry one.
///
/// This is the producer half of the coordinate: the thing that lets SimCrux say not just
/// *"open this trace"* but *"open this trace **here**"*. It is pure — no IO,
/// no Riverpod — so the decision can be tested directly and so the dispatcher
/// stays the only thing that touches the filesystem.
///
/// ## Null is the common answer, and it is a result rather than a gap
///
/// CXP §9.9 rule 3: **a producer MUST NOT emit a coordinate whose
/// `sequence_index` it cannot state in the named stream's own index space.**
/// A coordinate the receiver cannot resolve, or can resolve to the wrong
/// element, is worse than no coordinate at all — the same judgement the
/// formal driver makes recording `riscv.formal.trace_unresolved` with a null
/// path, and the Pro dashboards make disabling a button with an explanation
/// rather than dispatching into a guaranteed failure. Every `return null` below is that rule applied.
///
/// ## Architectural-compatibility rows carry no coordinate. This is the
/// finding, not an omission.
///
/// It is tempting to turn `riscv.signature.byte_offset` into "diverged at
/// instruction N". **That mapping does not exist.** An architectural
/// signature is machine state dumped at the *end* of a test, not a retire
/// log. Word *N* of it is the *N*th value the test stored into the signature
/// region; recovering which retirement performed that store requires the
/// execution trace, and the number of instructions that retired before it is
/// a property of the program and the core, not of the signature. Two cores
/// that both diverge at word 12 will have diverged at different instructions.
///
/// The second reason is decisive on its own: [RiscvArchDriver] declares
/// `supportsVcd: false`. A compatibility row has **no trace at all**, so
/// there is no decoded stream for a coordinate to address and nothing for a
/// receiver to open. Addressing the signature *as* a stream — which the
/// generic `(stream_id, sequence_index)` shape would permit — was considered
/// and rejected for the same reason: it would name an element that no peer in
/// the suite can display, which is a coordinate that cannot be resolved.
///
/// So the compatibility hand-off stays the offset on screen,
/// in the signature diff viewer, where the user already is.
///
/// ## Failing bounded proofs do carry one
///
/// A counterexample has a VCD and a step number `sby` itself printed, so the
/// coordinate is stated rather than inferred: `riscv.formal.trace_step` with
/// `sequence_index` = the depth reached and `sub_id` = the RVFI channel the
/// check was written against.
///
/// It is deliberately **not** `riscv.rvfi.retire`. That stream is indexed by
/// `rvfi_order`, and SimCrux does not know it: converting "seven cycles" into
/// "the Nth retirement" needs the trace, and how many instructions a core
/// retires in seven cycles is a property of the core under proof. WaveCrux
/// holds the decoded trace and does that conversion. **Whoever holds the
/// decoded stream owns the index conversion**; the alternative is this
/// function guessing an `rvfi_order`, which is precisely the fake index
/// §9.9 rule 3 exists to forbid.
///
/// ## Demo rows do emit, deliberately
///
/// A row replayed from committed fixtures (`riscv.mode = demo`) carries a
/// real VCD on disk and a real step from the replayed log, so the coordinate
/// **resolves** — and resolvability is what the honesty rule is about.
/// Suppressing it would break the offline demo that demo mode exists to
/// protect, for no gain in truthfulness. Provenance is not lost: the mode
/// rides along as the `riscv.mode` attribute (a key CXP §9.9.2,
/// https://edacrux.app/cxp#sec-9-9-2, registers for
/// exactly this), so a receiver can label replayed evidence as replayed
/// rather than infer that a solver ran.
CxpStreamCoordinate? riscvStreamCoordinateFor(TestResult result) {
  if (!RiscvResultKind.isFormalPropertyRow(result)) {
    // Architectural-compatibility rows and everything else. See the class
    // doc: a signature byte offset is not a retire index and there is no
    // trace to address.
    return null;
  }
  final metrics = result.metrics;

  // Only a counterexample has a trace. `UNKNOWN` / `TIMEOUT` / `ERROR` /
  // `NO_OUTCOME` learned nothing, and `PASS` proved the property — emitting a
  // coordinate for any of them would imply a counterexample exists, which is
  // the one thing the Pro formal dashboard's card is built to never say.
  final verdict = RiscvFormalVerdict.fromWireName(
    metrics[RiscvFormalDriver.kMetricVerdict],
  );
  if (verdict != RiscvFormalVerdict.fail) return null;

  // No resolvable trace, no coordinate. The formal driver leaves `waveformPath` null exactly
  // when `sby` announced a trace it could not resolve on disk
  // (`riscv.formal.trace_unresolved`), so this one test covers both "there
  // was never a trace" and "the trace is gone".
  final waveformPath = result.waveformPath;
  if (waveformPath == null || waveformPath.isEmpty) return null;

  // The step the assertion fired at. Absent means `sby` did not report a
  // depth, and step 0 — the trace's initial state — is a real, wrong answer
  // rather than a null-ish one, so a missing depth must produce no
  // coordinate rather than a coordinate at the top of the trace.
  final step = int.tryParse(
    metrics[RiscvFormalDriver.kMetricDepthReached] ?? '',
  );
  if (step == null || step < 0) return null;

  final attributes = <String, String>{
    RiscvFormalDriver.kMetricCheck: ?metrics[RiscvFormalDriver.kMetricCheck],
    RiscvFormalDriver.kMetricGroup: ?metrics[RiscvFormalDriver.kMetricGroup],
    RiscvFormalDriver.kMetricVerdict: RiscvFormalVerdict.fail.wireName,
    RiscvFormalDriver.kMetricDepthConfigured:
        ?metrics[RiscvFormalDriver.kMetricDepthConfigured],
    CxpStreamCoordinate.riscvIsaAttribute: ?metrics[RiscvArchDriver.kMetricIsa],
    CxpStreamCoordinate.riscvModeAttribute:
        ?metrics[RiscvArchDriver.kMetricMode],
  };

  final channel = metrics[RiscvFormalDriver.kMetricChannel];
  return CxpStreamCoordinate(
    streamId: CxpStreamCoordinate.riscvFormalTraceStepStreamId,
    sequenceIndex: step,
    subId: channel != null && channel.isNotEmpty ? channel : null,
    attributes: attributes,
  );
}
