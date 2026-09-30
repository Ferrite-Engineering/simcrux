// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:simcrux/core/theme/simcrux_colors.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// The localized name of a [TestStatus].
///
/// Public and shared because three surfaces need the same mapping: the filter
/// chips, the results-table row's screen-reader label, and anything else that
/// has to say a status out loud rather than draw it. A second copy is how a
/// status ends up announced by its enum name in one place and translated in
/// another.
String testStatusLabel(L10N l10n, TestStatus status) => switch (status) {
  TestStatus.pass => l10n.testStatusPass,
  TestStatus.fail => l10n.testStatusFail,
  TestStatus.running => l10n.testStatusRunning,
  TestStatus.skipped => l10n.testStatusSkipped,
  TestStatus.timeout => l10n.testStatusTimeout,
  TestStatus.cancelled => l10n.testStatusCancelled,
  TestStatus.vacuous => l10n.testStatusVacuous,
  TestStatus.cover => l10n.testStatusCover,
  TestStatus.unknown => l10n.testStatusUnknown,
};

/// A small icon that conveys a [TestStatus] at-a-glance in the
/// dashboard's results table.
///
/// The hue comes from [SimcruxColors.statusColor] — the one source of
/// truth shared with the heatmap cell, the test-browser icon, and the
/// web status chip — so a given status is a single color everywhere.
/// Tooltip and semantic label are localized via [L10N].
class DashboardStatusIcon extends StatelessWidget {
  /// Creates a [DashboardStatusIcon].
  const DashboardStatusIcon({
    required this.status,
    super.key,
    this.size = 20,
  });

  /// The status to render.
  final TestStatus status;

  /// Icon size in logical pixels (matches the row's text scale).
  final double size;

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    final theme = Theme.of(context);

    final color = SimcruxColors.statusColor(status, theme.colorScheme);
    final IconData icon;
    final String tooltip;
    switch (status) {
      case TestStatus.pass:
        icon = Icons.check_circle;
        tooltip = l10n.testStatusPass;
      case TestStatus.fail:
        icon = Icons.cancel;
        tooltip = l10n.testStatusFail;
      case TestStatus.running:
        icon = Icons.play_circle_outline;
        tooltip = l10n.testStatusRunning;
      case TestStatus.skipped:
        icon = Icons.remove_circle_outline;
        tooltip = l10n.testStatusSkipped;
      case TestStatus.timeout:
        icon = Icons.hourglass_disabled;
        tooltip = l10n.testStatusTimeout;
      case TestStatus.cancelled:
        icon = Icons.block;
        tooltip = l10n.testStatusCancelled;
      case TestStatus.vacuous:
        icon = Icons.check_circle_outline;
        tooltip = l10n.testStatusVacuous;
      case TestStatus.cover:
        icon = Icons.bubble_chart;
        tooltip = l10n.testStatusCover;
      case TestStatus.unknown:
        icon = Icons.help_outline;
        tooltip = l10n.testStatusUnknown;
    }
    return Tooltip(
      message: tooltip,
      child: Icon(icon, color: color, size: size, semanticLabel: tooltip),
    );
  }
}
