// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_updates/crux_updates.dart';

/// SimCrux's binding of the cross-suite [CruxUpdateConfig].
///
/// One instance, spread into the root `ProviderScope` through
/// `cruxUpdateConfigProvider` (see
/// `lib/features/update/providers/update_overrides.dart`). Everything the
/// update mechanism needs to know about *this* product lives here; the
/// mechanism itself is `package:crux_updates`.
///
/// **`checkOnMobile` is deliberately `false`** — and never reached. SimCrux
/// ships no iOS/Android target at all, so the mobile branch of
/// `updateCheckServiceProvider` is dead code in a SimCrux build. Leaving the
/// suite default keeps the declaration honest: if an iPadOS read-only viewer
/// ever lands, it inherits the correct store-build behaviour without a source
/// change.
///
/// **Web.** SimCrux *does* ship a read-only dashboard viewer on the web
/// (`app.simcrux.app`, built from this same open-core package). The
/// shared `UpdateBanner` never renders on web, which is the behaviour we want:
/// the web viewer self-updates on deploy, so a "download the new version"
/// strip would be noise that fires transiently around every release. The
/// *check* still runs there, and that is also wanted — its sole remaining job
/// on web is to observe the manifest's `server_time` watermark that hardens
/// the beta-expiry clock (see
/// `lib/features/update/providers/observed_server_time_provider.dart`).
final CruxUpdateConfig simcruxUpdateConfig = CruxUpdateConfig(
  productName: 'SimCrux',
  manifestUri: kSimcruxUpdateManifestUrl,
  downloadPageUri: kSimcruxDownloadPageUrl,
);

/// The public version-manifest endpoint polled by the update check.
const String kSimcruxUpdateManifestUrl =
    'https://updates.simcrux.app/manifest.json';

/// The SimCrux download page — the "Update Now" target, and the destination of
/// the beta-expiry banner / blocking-modal download actions.
const String kSimcruxDownloadPageUrl = 'https://simcrux.app/download';
