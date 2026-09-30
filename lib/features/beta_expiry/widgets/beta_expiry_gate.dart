// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async' show unawaited;

import 'package:crux_license/crux_license.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/core/update/simcrux_update_config.dart';
import 'package:simcrux/features/beta_expiry/widgets/beta_expiry_blocking_overlay.dart';
import 'package:simcrux/features/beta_expiry/widgets/beta_expiry_metrics.dart';
import 'package:simcrux/features/beta_expiry/widgets/beta_expiry_strings.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/lifecycle/app_exit_coordinator.dart';
import 'package:simcrux/services/lifecycle/app_exit_provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// Seam for opening the "download the latest build" page. Overridable in tests
/// so the banner / modal actions can be exercised without the `url_launcher`
/// platform channel.
Future<bool> Function(Uri uri) betaExpiryLaunchUrl = launchUrl;

/// Startup/resume gate enforcing the per-release hard beta build-expiry.
///
/// Wraps the routed app content ([child]) and, based on
/// `crux_license`'s `betaExpiryStatusProvider`:
///
/// - [BetaExpiryStatus.expiringSoon] → a dismissible [CruxBetaExpiryBanner]
///   above [child].
/// - [BetaExpiryStatus.expired] → the blocking, non-dismissable
///   [BetaExpiryBlockingOverlay] over [child].
/// - [BetaExpiryStatus.active] / [BetaExpiryStatus.notApplicable] → [child]
///   unchanged. This is the common case and *every* developer build and
///   post-beta production build: the expiry date is injected per beta drop via
///   `--dart-define=BETA_EXPIRY=<yyyymmdd>`, and absent / `0` / invalid means
///   the build never expires. Expiry also only applies while `kBetaPeriod` is
///   `true`.
///
/// **Clock hardening.** The status is reckoned against
/// `trustedBetaExpiryNow(DateTime.now(), observedServerTime: …)` — the *later*
/// of the device clock and the manifest `server_time` watermark persisted by
/// `ObservedServerTimeStore`. Winding the device clock back therefore cannot
/// defer expiry below the last server time SimCrux has observed. That wiring
/// lives in `simcruxUpdateOverrides` (the `observedServerTimeProvider`
/// override); without it the hardening is inert, which is why there is a
/// regression test for the pairing rather than only for the pure function.
///
/// The status is read at startup (first build) and re-evaluated on app resume:
/// [didChangeAppLifecycleState] invalidates the expiry providers so they
/// re-read the clock, and clears the session dismissal so a warning the user
/// dismissed earlier re-surfaces. The check never runs mid-session — only on
/// the resume lifecycle edge — so an in-progress regression is never
/// interrupted by it.
///
/// Sits inside `MaterialApp` (so `L10N.of` resolves) but above the routed
/// content, and *outside* the `UpdateBanner` so a blocking expiry modal covers
/// the update strip. See `app.dart`'s `MaterialApp.builder`.
class BetaExpiryGate extends ConsumerStatefulWidget {
  /// Creates the gate wrapping [child].
  const BetaExpiryGate({required this.child, super.key});

  /// The routed app content the gate wraps.
  final Widget child;

  @override
  ConsumerState<BetaExpiryGate> createState() => _BetaExpiryGateState();
}

class _BetaExpiryGateState extends ConsumerState<BetaExpiryGate>
    with WidgetsBindingObserver {
  /// Whether the user dismissed the "expires soon" banner this session. Reset
  /// on app resume so a returning user is reminded again.
  bool _bannerDismissed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Re-evaluate expiry against the latest clock reading. The providers
    // capture the instant when first read, so invalidation forces a fresh
    // read — a build still inside its window at launch can cross into
    // expiringSoon / expired while the app was suspended.
    ref
      ..invalidate(betaExpiryStatusProvider)
      ..invalidate(betaExpiryDaysRemainingProvider);
    if (_bannerDismissed && mounted) {
      setState(() => _bannerDismissed = false);
    }
  }

  void _download() {
    unawaited(betaExpiryLaunchUrl(Uri.parse(kSimcruxDownloadPageUrl)));
  }

  /// Orderly shutdown from the expired modal's quit action.
  ///
  /// Routes through the same [AppExitCoordinator] the File → Quit action uses
  /// rather than a bare `exit(0)`: SimCrux owns simulator process trees, and
  /// terminating without reaping them orphans every running `vvp` /
  /// `verilator` / `make → python` chain plus its work directory. The
  /// coordinator's grace budget bounds the wait. `processExitProvider` is the
  /// injectable seam, so a widget test can assert the quit without killing the
  /// test runner.
  Future<void> _quit() async {
    await ref.read(appExitCoordinatorProvider).shutdown();
    ref.read(processExitProvider)(0);
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(betaExpiryStatusProvider);

    switch (status) {
      case BetaExpiryStatus.expired:
        return BetaExpiryBlockingOverlay(
          onDownload: _download,
          onQuit: () => unawaited(_quit()),
          child: widget.child,
        );
      case BetaExpiryStatus.expiringSoon:
        if (_bannerDismissed) return widget.child;
        final days = ref.watch(betaExpiryDaysRemainingProvider) ?? 0;
        return Column(
          children: [
            CruxBetaExpiryBanner(
              daysRemaining: days,
              onDownload: _download,
              onDismiss: () => setState(() => _bannerDismissed = true),
              strings: SimcruxBetaExpiryStrings(L10N.of(context)),
              // Icon and touch target match the package defaults exactly, so
              // only the body size is passed. It is NOT the package default
              // (which inherits from the theme): SimCrux renders the strip at
              // the same 13 dp as the blocking overlay it precedes and the
              // telemetry consent disclosure beside it, and
              // `telemetry_consent_surfaces_test.dart` pins that agreement.
              sizing: const CruxBetaExpirySizing(
                bodyTextSize: kBetaExpiryBodyFontSize,
              ),
            ),
            Expanded(child: widget.child),
          ],
        );
      case BetaExpiryStatus.active:
      case BetaExpiryStatus.notApplicable:
        return widget.child;
    }
  }
}
