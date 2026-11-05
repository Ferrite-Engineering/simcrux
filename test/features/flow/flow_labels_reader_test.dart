// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_flow/crux_flow.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/flow/flow_labels.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/l10n/generated/app_localizations_en.dart';
import 'package:simcrux/services/flow/flow_metric_keys.dart';
import 'package:simcrux/services/flow/flow_run_reading.dart';

FlowReading _reading(FlowKind kind, String reader, String version) =>
    FlowReading(
      run: FlowRun(
        ref: FlowRunRef(
          kind: kind,
          root: '/runs/r',
          tag: 'r',
          readerVersion: version,
          verified: true,
        ),
        verdict: FlowVerdict.met,
      ),
      reader: reader,
    );

/// The Flow Runs panel names the reader that read a run in words: its ids
/// and the nextpnr format names are not versions (simcrux#54).
void main() {
  final L10N words = L10NEn();

  test('the LibreLane reader is named with its release line', () {
    expect(
      FlowLabels.reader(
        words,
        _reading(FlowKind.librelane, FlowReaderIds.librelane, '3.0'),
      ),
      'Read by the LibreLane 3.0 reader',
    );
  });

  test('the nextpnr readers are named, with no version in brackets', () {
    expect(
      FlowLabels.reader(
        words,
        _reading(
          FlowKind.nextpnr,
          FlowReaderIds.nextpnrReport,
          'nextpnr-report',
        ),
      ),
      'Read by the nextpnr report reader',
    );
    expect(
      FlowLabels.reader(
        words,
        _reading(FlowKind.nextpnr, FlowReaderIds.nextpnrLog, 'nextpnr-log'),
      ),
      'Read by the nextpnr log reader',
    );
  });

  test('a reader with no name is shown by its id and version', () {
    expect(
      FlowLabels.reader(
        words,
        _reading(FlowKind.librelane, 'librelane-contract', '3.0.16'),
      ),
      words.flowReaderLine('librelane-contract', '3.0.16'),
    );
  });
}
