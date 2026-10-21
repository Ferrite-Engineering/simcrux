// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/formal_bucket.dart';
import 'package:simcrux/domain/models/formal_result_summary.dart';
import 'package:simcrux/services/simulator/riscv_formal_driver.dart';
import 'package:simcrux/services/simulator/sby_driver.dart';

// What a formal row may claim, read back from its metrics. The wording
// never resolves toward a proof: a bounded pass says its bound, an unknown
// bound says bounded, and a pass with no property says nothing was proved.

Map<String, String> _sby(String verdict, {String? mode, Object? depth}) =>
    <String, String>{
      SbyDriver.kMetricTool: 'sby',
      SbyDriver.kMetricVerdict: verdict,
      SbyDriver.kMetricMode: ?mode,
      if (depth != null) SbyDriver.kMetricDepthConfigured: '$depth',
    };

void main() {
  test("the literal keys are the drivers' own", () {
    expect(FormalResultSummary.kVerdictKey, SbyDriver.kMetricVerdict);
    expect(FormalResultSummary.kToolKey, SbyDriver.kMetricTool);
    expect(FormalResultSummary.kModeKey, SbyDriver.kMetricMode);
    expect(FormalResultSummary.kEngineKey, SbyDriver.kMetricEngine);
    expect(
      FormalResultSummary.kDepthConfiguredKey,
      SbyDriver.kMetricDepthConfigured,
    );
    expect(FormalResultSummary.kPropertiesKey, SbyDriver.kMetricProperties);
    expect(
      FormalResultSummary.kPropertiesFailedKey,
      SbyDriver.kMetricPropertiesFailed,
    );
    expect(
      FormalResultSummary.kPropertiesUndecidedKey,
      SbyDriver.kMetricPropertiesUndecided,
    );
    expect(
      FormalResultSummary.kAssertionsDisabledKey,
      SbyDriver.kMetricAssertionsDisabled,
    );
    expect(
      FormalResultSummary.kRiscvVerdictKey,
      RiscvFormalDriver.kMetricVerdict,
    );
    expect(
      FormalResultSummary.kRiscvProofModeKey,
      RiscvFormalDriver.kMetricProofMode,
    );
    expect(
      FormalResultSummary.kRiscvDepthConfiguredKey,
      RiscvFormalDriver.kMetricDepthConfigured,
    );
    expect(
      FormalResultSummary.kRiscvEngineKey,
      RiscvFormalDriver.kMetricEngine,
    );
  });

  group('fromMetrics', () {
    test('a simulation row is not formal', () {
      expect(FormalResultSummary.fromMetrics(const {}), isNull);
      expect(
        FormalResultSummary.fromMetrics(const {'sim.cycles': '100'}),
        isNull,
      );
    });

    test('an sby row reads its tool, mode, engine word and counts', () {
      final s = FormalResultSummary.fromMetrics({
        ..._sby('PASS', mode: 'prove'),
        SbyDriver.kMetricEngine: 'smtbmc',
        SbyDriver.kMetricProperties: '3',
        SbyDriver.kMetricPropertiesFailed: '0',
        SbyDriver.kMetricPropertiesUndecided: '1',
      })!;
      expect(s.tool, 'sby');
      expect(s.mode, 'prove');
      expect(s.engine, 'smtbmc');
      expect(s.properties, 3);
      expect(s.propertiesUndecided, 1);
    });

    test('a RISC-V row is riscv_formal, even when it also carries the '
        'general keys', () {
      final both = FormalResultSummary.fromMetrics({
        RiscvFormalDriver.kMetricVerdict: 'FAIL',
        ..._sby('FAIL', mode: 'bmc'),
      })!;
      expect(both.tool, 'riscv_formal');
      final legacy = FormalResultSummary.fromMetrics(const {
        'riscv.formal.verdict': 'PASS',
        'riscv.formal.proof_mode': 'bmc',
        'riscv.formal.depth_configured': '20',
        'riscv.formal.engine': 'smtbmc boolector',
      })!;
      expect(legacy.tool, 'riscv_formal');
      expect(legacy.mode, 'bmc');
      expect(legacy.depthConfigured, 20);
      expect(legacy.engine, 'smtbmc');
    });

    test('an eqy row is eqy', () {
      final s = FormalResultSummary.fromMetrics(const {
        'formal.tool': 'eqy',
        'formal.verdict': 'PASS',
      })!;
      expect(s.tool, 'eqy');
    });
  });

  group('wording', () {
    FormalVerdictWording w(Map<String, String> m) =>
        FormalResultSummary.fromMetrics(m)!.wording;

    test('an unbounded pass is a proof', () {
      expect(w(_sby('PASS', mode: 'prove')), FormalVerdictWording.proved);
      expect(w(_sby('PASS', mode: 'live')), FormalVerdictWording.proved);
    });

    test('a BMC pass is proved over its configured steps, never a bare '
        'proof', () {
      final s = FormalResultSummary.fromMetrics(
        _sby('PASS', mode: 'bmc', depth: 20),
      )!;
      expect(s.wording, FormalVerdictWording.provedOverSteps);
      expect(s.depthConfigured, 20);
    });

    test('a pass with no mode or no bound recorded is worded as bounded', () {
      expect(w(_sby('PASS')), FormalVerdictWording.provedBounded);
      expect(w(_sby('PASS', mode: 'bmc')), FormalVerdictWording.provedBounded);
      expect(
        w(_sby('PASS', mode: 'bmc', depth: 0)),
        FormalVerdictWording.provedBounded,
      );
    });

    test('a cover pass reached its covers; a cover fail did not', () {
      expect(w(_sby('PASS', mode: 'cover')), FormalVerdictWording.reached);
      expect(w(_sby('FAIL', mode: 'cover')), FormalVerdictWording.notReached);
    });

    test('a pass that checked no property proved nothing', () {
      final m = {
        ..._sby('PASS', mode: 'prove'),
        SbyDriver.kMetricProperties: '0',
      };
      expect(w(m), FormalVerdictWording.noPropertiesChecked);
      expect(
        FormalResultSummary.fromMetrics(m)!.bucket,
        FormalBucket.proved,
        reason: 'the stored verdict is unchanged; only the wording is',
      );
    });

    test('the other buckets', () {
      expect(w(_sby('FAIL', mode: 'bmc')), FormalVerdictWording.counterexample);
      expect(w(_sby('UNKNOWN')), FormalVerdictWording.inconclusive);
      expect(w(_sby('TIMEOUT')), FormalVerdictWording.inconclusive);
      expect(w(_sby('ERROR')), FormalVerdictWording.didNotRun);
      expect(w(_sby('NO_OUTCOME')), FormalVerdictWording.didNotRun);
      expect(w(_sby('SOMETHING_NEW')), FormalVerdictWording.unrecognised);
    });

    test('the sort puts the most urgent first and proofs last', () {
      int rank(Map<String, String> m) =>
          FormalResultSummary.fromMetrics(m)!.sortRank;
      expect(rank(_sby('FAIL')), lessThan(rank(_sby('ERROR'))));
      expect(rank(_sby('ERROR')), lessThan(rank(_sby('UNKNOWN'))));
      expect(
        rank({..._sby('PASS'), SbyDriver.kMetricProperties: '0'}),
        lessThan(rank(_sby('PASS', mode: 'prove'))),
      );
    });
  });
}
