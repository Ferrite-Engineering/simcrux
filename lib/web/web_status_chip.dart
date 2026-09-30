// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:simcrux/core/theme/simcrux_colors.dart';
import 'package:simcrux/domain/enums/test_status.dart';

/// Compact colored chip rendering a [TestStatus] inside the web
/// dashboard's table and inspector dialog.
class WebStatusChip extends StatelessWidget {
  /// Creates a [WebStatusChip].
  const WebStatusChip(this.status, {super.key});

  /// The test status the chip represents.
  final TestStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = _colorsFor(status, theme);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.foreground.withValues(alpha: 0.4)),
      ),
      child: Text(
        status.name.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: scheme.foreground,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  ({Color background, Color foreground}) _colorsFor(
    TestStatus status,
    ThemeData theme,
  ) {
    // Same per-status hue as the desktop dashboard surfaces (see
    // SimcruxColors.statusColor): the chip fills with a translucent wash
    // of the token and draws its label in the solid token so a status is
    // one recognizable color across desktop and web.
    final base = SimcruxColors.statusColor(status, theme.colorScheme);
    return (background: base.withValues(alpha: 0.15), foreground: base);
  }
}
