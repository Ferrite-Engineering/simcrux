// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:simcrux/core/app_info/about_providers.dart';
import 'package:simcrux/core/simcrux_url_launcher.dart';
import 'package:simcrux/core/telemetry/simcrux_telemetry_config.dart';
import 'package:simcrux/core/telemetry/simcrux_telemetry_storage.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/services/telemetry/telemetry_platform.dart';

/// Root-scope overrides binding the cross-suite `crux_telemetry` package to
/// SimCrux's own configuration, persistence, build metadata, layout idiom,
/// locale, and URL launcher.
///
/// Spread into the root `ProviderContainer` by `bootstrap`, ahead of the
/// Pro overlay's `proOverrides` so the overlay can layer on top
/// under the standard later-wins conflict semantics — that is where the
/// Enterprise `.crux-policy.json` `telemetry: allow | deny` key will bind, as
/// an override of `telemetryConsentPromptVisibleProvider`.
///
/// The localized string bundle is deliberately **not** here: it needs a
/// `BuildContext` to resolve `L10N.of(context)`, so `SimcruxApp` overrides
/// `cruxTelemetryStringsProvider` from inside `MaterialApp.builder` instead —
/// exactly as it does for `cruxUpdateStringsProvider`.
///
/// Also used by the headless `--ci` path, which builds a transient container
/// from these same overrides. That is the point: the CI runner reads the
/// consent the GUI wrote, through the same storage adapter, rather than
/// through a second consent channel that could drift from the first. See
/// `services/telemetry/headless_telemetry.dart`.
final List<Override> simcruxTelemetryOverrides = <Override>[
  // The one binding with no working default. A product that forgets it throws
  // at wiring rather than reporting somebody else's product slug on every
  // batch — and a wrong slug is rejected by the Worker with a 400 the client
  // never sees.
  cruxTelemetryConfigProvider.overrideWithValue(simcruxTelemetryConfig),

  // Where `telemetry.consent` and `telemetry.installationId` live. The package
  // default is an in-memory store, which would re-prompt the disclosure every
  // launch, re-mint the installation id every session, and — because `--ci`
  // reads the same two keys — leave every headless run permanently unable to
  // see the GUI's answer.
  telemetryStorageProvider.overrideWithValue(const SimcruxTelemetryStorage()),

  // "Learn more" on both consent surfaces. The package default throws rather
  // than silently doing nothing when the user taps a link on a privacy notice.
  // Bound through SimCrux's own mutable `simcruxLaunchUrl` seam (not
  // `url_launcher`'s `launchUrl` directly) so widget tests that swap the seam
  // reach this link too.
  telemetryUrlLauncherProvider.overrideWith((_) => simcruxLaunchUrl),

  // The `app_version` envelope field. Until this resolves the package's
  // envelope resolver returns null and the flush skips — a version we do not
  // have must not be invented, because a bad `app_version` rejects the whole
  // batch at the Worker.
  telemetryAppVersionProvider.overrideWith(
    (ref) async => (await ref.watch(aboutBuildInfoProvider.future)).version,
  ),

  // The `form_factor` bucket, derived from the layout idiom the app actually
  // drew. This stays in SimCrux on purpose: a second breakpoint set inside
  // `crux_telemetry` is how telemetry would come to disagree with what the
  // user is looking at. SimCrux has no device-class system, so the derivation
  // has exactly the two arms the app actually has — see
  // [telemetryFormFactorFor].
  //
  // The seam is `Provider<String?>` so a product whose idiom comes from the
  // widget tree can answer "not yet" and have the flush skip rather than report
  // a pre-layout default — WaveCrux needs that, because a Pixel Tablet in
  // portrait reported `desktop` on three of four launches before layout. **SimCrux must not do that.**
  // `kIsWeb` is a compile-time constant and there is no second input: the
  // answer is known before anything is drawn, so deferring would cost a flush
  // interval to answer a question that was never open.
  telemetryFormFactorProvider.overrideWith(
    (_) => telemetryFormFactorFor(isWeb: kIsWeb),
  ),

  // The display language actually in effect — the field that answers whether
  // the zh/zh_CN/ja/ko localizations earn their maintenance cost. Falls back to
  // the seam default while settings are still loading; a flush that early has
  // nothing queued to send anyway.
  telemetryLocaleProvider.overrideWith(
    (ref) => ref.watch(appSettingsProvider).value?.core.locale ?? 'en',
  ),
];
