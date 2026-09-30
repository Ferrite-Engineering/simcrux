// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/models/config_loader_error.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/features/dashboard/providers/config_load_warnings_provider.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// The active project's load advisories, above the results table.
///
/// A project can load with warnings — most often a `seeds:` or list-valued
/// `parameters:` sweep that the license tier did not expand, so the test runs
/// once. Nothing used to show them, so the sweep silently ran once. The banner
/// lists each advisory as `path:line:col: message` (selectable, so it can be
/// copied), is announced politely when a project loads with any, and can be
/// dismissed until a load brings different advisories.
///
/// Renders nothing when there are no advisories or when
/// [showConfigLoadWarningsProvider] is false.
class ConfigLoadWarningsBanner extends ConsumerStatefulWidget {
  /// Creates a [ConfigLoadWarningsBanner].
  const ConfigLoadWarningsBanner({super.key});

  @override
  ConsumerState<ConfigLoadWarningsBanner> createState() =>
      _ConfigLoadWarningsBannerState();
}

class _ConfigLoadWarningsBannerState
    extends ConsumerState<ConfigLoadWarningsBanner> {
  /// The advisories the user dismissed. A load that produces different
  /// advisories publishes a new config, which brings the banner back.
  List<ConfigLoaderError>? _dismissed;

  @override
  void initState() {
    super.initState();
    ref.listenManual<RegressionConfig?>(activeConfigProvider, (
      previous,
      next,
    ) {
      final warnings = next?.loadWarnings ?? const <ConfigLoaderError>[];
      if (warnings.isEmpty || identical(previous?.loadWarnings, warnings)) {
        return;
      }
      if (!ref.read(showConfigLoadWarningsProvider)) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        announceCrux(
          context,
          L10N.of(context).configLoadWarningsTitle(warnings.length),
        );
      });
    }, fireImmediately: true);
  }

  @override
  Widget build(BuildContext context) {
    final warnings =
        ref.watch(activeConfigProvider)?.loadWarnings ??
        const <ConfigLoaderError>[];
    if (warnings.isEmpty ||
        !ref.watch(showConfigLoadWarningsProvider) ||
        identical(_dismissed, warnings)) {
      return const SizedBox.shrink();
    }
    final l10n = L10N.of(context);
    final theme = Theme.of(context);
    final onColor = theme.colorScheme.onSecondaryContainer;
    return Material(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                Icons.warning_amber_rounded,
                size: 20,
                color: onColor,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l10n.configLoadWarningsTitle(warnings.length),
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: onColor,
                    ),
                  ),
                  const SizedBox(height: 4),
                  for (final warning in warnings)
                    SelectableText(
                      warning.format(),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: onColor,
                      ),
                    ),
                ],
              ),
            ),
            TextButton(
              onPressed: () => setState(() => _dismissed = warnings),
              child: Text(l10n.configLoadWarningsDismiss),
            ),
          ],
        ),
      ),
    );
  }
}
