// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Adapter that satisfies the cross-suite [CruxTelemetryStrings] interface from
/// `package:crux_telemetry` using SimCrux's ARB-generated [L10N] strings.
///
/// `crux_shared` packages carry no ARB files, so every product supplies an
/// adapter of this shape — the same pattern as [SimcruxUpdateStrings] and the
/// issue-reporter adapter.
///
/// The product name lives in SimCrux's own ARB entry ("Help make SimCrux
/// better"), which is why [consentTitle] takes no parameter: nothing is
/// interpolated across the seam, so ICU placeholder ordering stays entirely
/// inside the ARB file and the five-locale parity sweep stays a SimCrux test.
class SimcruxTelemetryStrings extends CruxTelemetryStrings {
  /// Wraps the supplied [L10N] so the package's consent surfaces render in the
  /// active locale.
  const SimcruxTelemetryStrings(this._l10n);

  final L10N _l10n;

  // ── The disclosure ─────────────────────────────────────────────────────────

  @override
  String get consentTitle => _l10n.telemetryConsentTitle;

  @override
  String get consentBody => _l10n.telemetryConsentBody;

  @override
  String get learnMore => _l10n.telemetryConsentLearnMore;

  @override
  String get consentToggleLabel => _l10n.telemetryConsentToggleLabel;

  @override
  String get consentContinue => _l10n.telemetryConsentContinue;

  // ── Settings → Privacy ─────────────────────────────────────────────────────

  @override
  String get settingsToggleLabel => _l10n.settingsTelemetryLabel;

  @override
  String get settingsToggleDescription => _l10n.settingsTelemetryDescription;

  @override
  String get settingsDocsLabel => _l10n.settingsTelemetryDocsLabel;

  @override
  String get settingsDocsDescription => _l10n.settingsTelemetryDocsDescription;

  @override
  String get settingsInstallationIdLabel =>
      _l10n.settingsTelemetryInstallationIdLabel;

  @override
  String get settingsInstallationIdDescription =>
      _l10n.settingsTelemetryInstallationIdDescription;

  @override
  String get settingsInstallationIdCopy =>
      _l10n.settingsTelemetryInstallationIdCopy;

  @override
  String get settingsInstallationIdCopied =>
      _l10n.settingsTelemetryInstallationIdCopied;
}
