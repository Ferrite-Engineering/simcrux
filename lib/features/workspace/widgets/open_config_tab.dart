// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/services/crux_project_resolution.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/telemetry/project_opened_event.dart';

/// The user-facing sentence for a manifest SimCrux cannot open.
String cruxProjectRefusalMessage(L10N l10n, ManifestUnusable refusal) =>
    switch (refusal) {
      ManifestInvalid(:final detail) => l10n.cruxProjectInvalid(detail),
      ManifestConfigMissing(:final configPath) => l10n.cruxProjectConfigMissing(
        configPath,
      ),
      ManifestNoSimulation(:final displayName) => l10n.cruxProjectNoSimulation(
        displayName,
      ),
      ManifestAmbiguous(:final directory, :final candidates) =>
        l10n.cruxProjectAmbiguous(
          directory,
          candidates.map(p.basename).join(', '),
        ),
    };

/// Opens [rawPath] as a workspace tab and records how the user got here.
///
/// [rawPath] is a `simcrux.yaml` (or a `.simcrux-session`), a
/// `<design>.crux-project` manifest, or a design directory holding exactly
/// one manifest. A manifest is swapped for the `simulation` config it names
/// before anything else runs, so recents, telemetry and tab creation behave
/// exactly as they do for a directly-opened config. Every open route — the
/// empty-canvas and File-menu pickers and the command line — goes through
/// here, so a manifest opens the same way from each.
///
/// Feedback goes to [context]'s snack-bar messenger, once per open: a
/// legacy bare `.crux-project` opens and says what to rename it to; a
/// manifest that names nothing openable, or a directory holding several
/// manifests, opens nothing and says why. A null or unmounted [context] only
/// drops the feedback.
///
/// [source] is the `project.opened` route token and is required because the
/// callers answer it differently. [addToRecents] is false for the command
/// line, which opens without touching the recents list.
///
/// Returns the config path the tab opened, or null when nothing opened.
Future<String?> openConfigAsTab({
  required WidgetRef ref,
  required BuildContext? context,
  required String rawPath,
  required String source,
  bool addToRecents = true,
  CruxProjectResolver resolver = const CruxProjectResolver(),
}) async {
  final resolution = resolver.resolve(rawPath);
  final l10n = context != null && context.mounted ? L10N.of(context) : null;
  final String path;
  switch (resolution) {
    case NotAManifest(path: final passthrough):
      path = passthrough;
    case final ManifestSimulation simulation:
      path = simulation.configPath;
      if (simulation.isLegacyFileName && l10n != null && context != null) {
        showCruxInfoSnack(
          context,
          l10n.cruxProjectLegacyFileName(simulation.suggestedFileName),
        );
      }
    case final ManifestUnusable refusal:
      if (l10n != null && context != null) {
        showCruxErrorSnack(context, cruxProjectRefusalMessage(l10n, refusal));
      }
      return null;
  }

  if (addToRecents) {
    unawaited(ref.read(appSettingsProvider.notifier).addRecentProject(path));
  }
  ref.read(telemetryServiceProvider).record(projectOpenedEvent(source));
  await ref
      .read(workspaceProvider.notifier)
      .openTab(
        displayName: p.basename(path),
        payload: SimcruxTabPayload(configPath: path),
      );
  return path;
}
