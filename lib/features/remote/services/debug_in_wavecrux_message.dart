// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/features/remote/services/debug_in_wavecrux_dispatcher.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// What the user is told after a "Debug in WaveCrux" dispatch: the one
/// sentence every surface that hands a waveform to WaveCrux shows (the
/// inspector's button, Open Gate-Level Waveform).
///
/// A peer's own explanation travels verbatim: nothing local could describe
/// what WaveCrux found in the trace.
String debugInWaveCruxMessage(
  L10N l10n,
  DebugInWaveCruxResult result,
) => switch (result.outcome) {
  DebugInWaveCruxOutcome.dispatched => l10n.debugInWavecruxDispatched(
    result.targetPeerId ?? '',
  ),
  DebugInWaveCruxOutcome.dispatchedWithLimitation =>
    l10n.debugInWavecruxPartial(result.reason ?? ''),
  DebugInWaveCruxOutcome.rejected => l10n.debugInWavecruxRejected(
    result.reason ?? '',
  ),
  DebugInWaveCruxOutcome.unacknowledged => l10n.debugInWavecruxUnacknowledged,
  DebugInWaveCruxOutcome.noPeer => l10n.debugInWavecruxNoPeer,
  DebugInWaveCruxOutcome.serverDisabled => l10n.debugInWavecruxServerDisabled,
  DebugInWaveCruxOutcome.noWaveform => l10n.debugInWavecruxNoWaveform,
  DebugInWaveCruxOutcome.waveformMissing => l10n.debugInWavecruxWaveformMissing,
};

/// Whether [result] is good news: only a clean acknowledgement is. A partly
/// honoured hand-off is reported like a failure on purpose: the trace opened,
/// but landing where the user asked did not happen.
bool debugInWaveCruxSucceeded(DebugInWaveCruxResult result) =>
    result.outcome == DebugInWaveCruxOutcome.dispatched;
