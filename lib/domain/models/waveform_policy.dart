// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/domain/enums/waveform_capture_policy.dart';
import 'package:simcrux/domain/enums/waveform_format.dart';

/// Per-test (or per-suite, inherited) waveform-capture configuration.
///
/// Maps directly to the `waveform:` section in `simcrux.yaml`.
@immutable
class WaveformPolicy {
  /// Creates a [WaveformPolicy].
  const WaveformPolicy({
    this.capture = WaveformCapturePolicy.onFailure,
    this.format = WaveformFormat.fst,
  });

  /// When to capture the waveform.
  final WaveformCapturePolicy capture;

  /// The dump format to request from the simulator.
  final WaveformFormat format;

  /// Returns a copy with the given fields replaced.
  WaveformPolicy copyWith({
    WaveformCapturePolicy? capture,
    WaveformFormat? format,
  }) {
    return WaveformPolicy(
      capture: capture ?? this.capture,
      format: format ?? this.format,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is WaveformPolicy &&
        other.capture == capture &&
        other.format == format;
  }

  @override
  int get hashCode => Object.hash(capture, format);
}
