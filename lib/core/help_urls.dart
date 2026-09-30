// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// Outbound URLs SimCrux opens in the user's browser.
///
/// Defined in one place so the destinations cannot drift between the update
/// banner, the beta-expiry gate, and the Help menu. Mirrors WaveCrux's
/// `HelpUrls`.
abstract final class HelpUrls {
  /// SimCrux documentation home — the Help → Documentation target.
  static const String docs = 'https://docs.simcrux.app';

  /// SimCrux marketing / home page.
  static const String website = 'https://simcrux.app';

  /// The SimCrux desktop download page.
  static const String download = 'https://simcrux.app/download';

  /// Privacy policy. One suite-wide policy lives on edacrux.app; the old
  /// simcrux.app/privacy page is only a redirect to it.
  static const String privacyPolicy = 'https://edacrux.app/privacy';

  /// Terms of service, suite-wide on edacrux.app like the privacy policy.
  static const String termsOfService = 'https://edacrux.app/terms';

  /// Suite home — the target of the welcome screen's suite-membership line.
  ///
  /// A per-product path rather than the shared `/products` page, and that is
  /// the whole point: the site's page-view beacon records the path and
  /// deliberately drops the query string, so `?from=simcrux` would be
  /// invisible and a desktop app sends no referrer. The path is how the visit
  /// is attributed to the app that sent it.
  static const suiteHome = 'https://edacrux.app/from/simcrux';

  /// The suite landing path, scrolled to one peer product's card.
  ///
  /// The fragment is free: the site's beacon drops it before sending, so this
  /// is still recorded as `/from/simcrux` and the per-product attribution is
  /// unaffected — while the reader still lands on the product the row named
  /// rather than at the top of a page listing three.
  static String suitePeer(String slug) => '$suiteHome#$slug';

  // Contextual documentation, `https://docs.simcrux.app/<page>#<section>`.
  // Targets of the in-app `CruxHelpLink` icons. Each page is
  // `docs-site/docs/<page>.md` and each section its `{#<section>}` heading
  // id; `test/core/help_urls_test.dart` holds the two together.

  /// Docs — run controls, including the auto-run-on-open setting.
  static const String runningTests =
      'https://docs.simcrux.app/running-tests#controls';

  /// Docs — the built-in color theme presets.
  static const String appearanceAndThemes =
      'https://docs.simcrux.app/appearance-and-themes#presets';

  /// Docs — the simcrux.yaml schema, including the Settings → Simulators
  /// binary path.
  static const String projectsAndSimulators =
      'https://docs.simcrux.app/projects-and-simulators#schema';

  /// Docs — the reusable detector library behind Settings → Detectors.
  static const String passFailDetection =
      'https://docs.simcrux.app/pass-fail-detection#library';

  /// Docs — cross-probe (CXP) and its settings.
  static const String integrations =
      'https://docs.simcrux.app/integrations#cxp';

  /// Docs — test-name search in the results dashboard.
  static const String resultsDashboard =
      'https://docs.simcrux.app/results-dashboard#search';
}
