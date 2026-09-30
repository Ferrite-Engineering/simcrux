// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license.dart';
import 'package:crux_updates/crux_updates.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:simcrux/core/app_info/about_providers.dart';
import 'package:simcrux/core/update/simcrux_update_config.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/update/providers/observed_server_time_provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// Root-container overrides that bind `package:crux_updates` to SimCrux.
///
/// Spread into `bootstrap()`'s root `ProviderContainer` *before*
/// `extraOverrides`, so the Pro overlay can layer its own binding on
/// top (open-core overrides first, Pro overrides last, later overrides win).
///
/// Six of the package's eight seams are bound here; the two that are not:
///
/// - `cruxUpdateStringsProvider` — needs a `BuildContext` for `L10N.of`, so it
///   is overridden from the widget layer inside `MaterialApp.builder`
///   (see `SimcruxApp.build`).
/// - `updateHttpClientProvider` — the package default constructs a real
///   `http.Client`; only tests override it, with a `MockClient`.
final List<Override> simcruxUpdateOverrides = <Override>[
  // The product configuration. Without this the package's default throws at
  // first read — deliberately, so a forgotten binding fails at app wiring
  // rather than silently never checking for updates.
  cruxUpdateConfigProvider.overrideWithValue(simcruxUpdateConfig),

  // The running build's version + OS, for the semver comparison and the
  // manifest fetch's `User-Agent`. Until this resolves the package falls back
  // to `NoopUpdateCheckService`, so a check racing startup reports "current"
  // rather than comparing against an unknown version.
  updateBuildInfoProvider.overrideWith(
    (ref) => ref.watch(aboutBuildInfoProvider.future),
  ),

  // The persisted Settings → General toggle. Gates the launch check, the
  // periodic timer and the on-resume re-check; never the manual action.
  autoUpdateCheckEnabledProvider.overrideWith(
    (ref) async =>
        (await ref.watch(appSettingsProvider.future)).autoCheckForUpdates,
  ),

  // The manifest's `server_time`, observed on every successful fetch, into the
  // persisted monotonic watermark.
  observedServerTimeSinkProvider.overrideWith(
    (ref) =>
        (serverTime) => ref
            .read(observedServerTimeStoreProvider.notifier)
            .record(serverTime),
  ),

  // Close the loop: `crux_license` reckons beta expiry against
  // `trustedBetaExpiryNow(DateTime.now(), observedServerTime: …)`, so the
  // watermark above is what stops a device-clock rollback from deferring
  // expiry. Without this override the two packages never meet and the
  // hardening is inert.
  observedServerTimeProvider.overrideWith(
    (ref) => ref.watch(observedServerTimeStoreProvider),
  ),

  // Whether paid features are unlocked, from the same gate the paid features
  // use. A seat without them is offered only releases that changed what it
  // gets (the manifest's `open_core_version`), so a release that touched only
  // Pro features puts no banner in front of free users. The Pro overlay's
  // licence binding drives `licenseTierProvider`; this follows it, and a key
  // entered mid-session re-presents the last check's result at once.
  updateEditionProvider.overrideWith(
    (ref) => UpdateEdition.of(
      paidFeaturesUnlocked:
          ref.watch(betaPeriodProvider) ||
          FeatureGate.satisfiesTier(
            LicenseTier.pro,
            ref.watch(licenseTierProvider),
          ),
    ),
  ),

  // "Update Now" / "View Changes" open a URL. The package default throws
  // rather than doing nothing, so a missing binding is loud.
  updateUrlLauncherProvider.overrideWithValue(launchUrl),
];
