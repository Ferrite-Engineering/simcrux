// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/remote/cxp_peer_display_name.dart';

void main() {
  test('suite wire ids read as product names', () {
    expect(cxpPeerDisplayName('wavecrux'), 'WaveCrux');
    expect(cxpPeerDisplayName('netcrux'), 'NetCrux');
    expect(cxpPeerDisplayName('lintcrux'), 'LintCrux');
    expect(cxpPeerDisplayName('simcrux'), 'SimCrux');
  });

  test('a peer outside the suite keeps the name it announced', () {
    expect(cxpPeerDisplayName('acme-sim'), 'acme-sim');
  });
}
