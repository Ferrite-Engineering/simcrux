// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/models/pass_fail_config_codec.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/services/config/config_loader.dart';

/// The [ConfigLoader] every in-app project load goes through: a tab loads
/// its `simcrux.yaml` via `RegressionRunner.startFromConfigPath`, which
/// reads this provider.
///
/// Exposed as its own provider so tests can override it with a
/// `ConfigLoader(readFile: ...)` constructed against an in-memory
/// fake — no need to hit the real filesystem.
///
/// The default implementation forwards the user's reusable detector
/// library from `AppSettings.reusableDetectors` so a `simcrux.yaml`
/// `pass_fail: { type: use, name: <name> }` block resolves against the
/// active settings.
///
/// The loader also receives the active [LicenseTier] from
/// [licenseTierProvider] so the parameterization tier-gate can
/// silently drop `seeds:` / `parameters:` sweep blocks on Open Core
/// builds post-beta. During the public-beta period
/// (`kBetaPeriod = true`) the gate short-circuits and parameterization
/// works regardless of tier; this provider passes the tier in anyway
/// so the gate behaves correctly the moment `kBetaPeriod` flips.
final Provider<ConfigLoader> configLoaderProvider = Provider<ConfigLoader>(
  (ref) {
    final settings = ref.watch(appSettingsProvider);
    final reusable =
        settings.value?.reusableDetectors ?? const <String, DetectorSpec>{};
    final tier = ref.watch(licenseTierProvider);
    return ConfigLoader(
      reusableDetectors: reusable,
      licenseTier: tier,
      // A project file may not choose which binary SimCrux spawns, or
      // its environment, unless the user has said so in
      // Settings → Simulators. Default off; see
      // `AppSettings.allowProjectDefinedTooling`.
      allowProjectDefinedTooling:
          settings.value?.allowProjectDefinedTooling ?? false,
    );
  },
);
