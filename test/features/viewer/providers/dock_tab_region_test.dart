// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/flow/providers/flow_providers.dart';
import 'package:simcrux/features/remote/providers/cross_probe_visibility_provider.dart';
import 'package:simcrux/features/viewer/providers/right_dock_provider.dart';

/// The two movable dock tabs, the cross-probe panel and Flow Runs, each
/// placed on its own: a drop re-homes the tab it carried and nothing else,
/// where it used to re-home the cross-probe tab whatever was dropped.
void main() {
  test('each movable tab starts in its own region', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(crossProbeDockRegionProvider), kDockRegionRight);
    expect(container.read(flowRunsDockRegionProvider), kDockRegionBottom);
  });

  test('moving one tab leaves the other where it was', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(dockTabRegionProvider.notifier)
        .move(kDockTabFlowRuns, kDockRegionRight);
    expect(container.read(flowRunsDockRegionProvider), kDockRegionRight);
    expect(container.read(crossProbeDockRegionProvider), kDockRegionRight);
    container
        .read(dockTabRegionProvider.notifier)
        .move(kRightDockTabCrossProbe, kDockRegionBottom);
    expect(container.read(crossProbeDockRegionProvider), kDockRegionBottom);
    expect(container.read(flowRunsDockRegionProvider), kDockRegionRight);
  });

  test('a pinned tab or an unknown region moves nothing', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final before = container.read(dockTabRegionProvider);
    container
        .read(dockTabRegionProvider.notifier)
        .move(kRightDockTabDetails, kDockRegionBottom);
    container
        .read(dockTabRegionProvider.notifier)
        .move(kDockTabFlowRuns, 'left');
    expect(container.read(dockTabRegionProvider), before);
  });

  test('Flow Runs is the right dock tab only when shown there', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(rightDockTabProvider.notifier).select(kDockTabFlowRuns);
    // Hidden, or in the bottom dock: Details.
    expect(
      container.read(effectiveRightDockTabProvider),
      kRightDockTabDetails,
    );
    container.read(flowRunsVisibleProvider.notifier).set(visible: true);
    expect(
      container.read(effectiveRightDockTabProvider),
      kRightDockTabDetails,
    );
    container
        .read(dockTabRegionProvider.notifier)
        .move(kDockTabFlowRuns, kDockRegionRight);
    expect(container.read(effectiveRightDockTabProvider), kDockTabFlowRuns);
    // Hidden again: the cross-probe panel, when shown, is the fallback.
    container.read(flowRunsVisibleProvider.notifier).set(visible: false);
    container.read(crossProbeVisibleProvider.notifier).set(visible: true);
    expect(
      container.read(effectiveRightDockTabProvider),
      kRightDockTabCrossProbe,
    );
  });
}
