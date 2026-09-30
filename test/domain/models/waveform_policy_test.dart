// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/waveform_capture_policy.dart';
import 'package:simcrux/domain/enums/waveform_format.dart';
import 'package:simcrux/domain/models/waveform_policy.dart';

void main() {
  group('WaveformPolicy', () {
    test('default is onFailure / FST', () {
      const policy = WaveformPolicy();
      expect(policy.capture, WaveformCapturePolicy.onFailure);
      expect(policy.format, WaveformFormat.fst);
    });

    test('copyWith replaces fields independently', () {
      const policy = WaveformPolicy();
      final cap = policy.copyWith(capture: WaveformCapturePolicy.always);
      expect(cap.capture, WaveformCapturePolicy.always);
      expect(cap.format, policy.format);

      final fmt = policy.copyWith(format: WaveformFormat.vcd);
      expect(fmt.format, WaveformFormat.vcd);
      expect(fmt.capture, policy.capture);
    });

    test('equality is value-based', () {
      const a = WaveformPolicy(format: WaveformFormat.vcd);
      const b = WaveformPolicy(format: WaveformFormat.vcd);
      const c = WaveformPolicy(format: WaveformFormat.ghw);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });
  });
}
