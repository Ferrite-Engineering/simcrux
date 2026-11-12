// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_theme/crux_theme.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// `AppLocalizations`-backed adapter that satisfies `crux_theme`'s
/// `ThemeAppearanceStrings` interface from SimCrux's ARB-generated
/// strings.
///
/// Used by [ColorThemeSection] to drive the Settings → Appearance
/// subsections in the active locale. Every getter routes to a
/// `L10N.appearance*` key — see `lib/l10n/app_en.arb` for the canonical
/// text and descriptions.
///
/// The class shadows `sectionTitle` to the existing
/// `settingsAppearanceSection` string so the heading matches the one the
/// Settings screen renders; every other slot pulls a dedicated
/// `appearance*` key from the ARB file.
class SimCruxThemeAppearanceStrings extends ThemeAppearanceStrings {
  /// Wraps [_l10n] so the [ThemeAppearanceStrings] interface returns
  /// localized strings from SimCrux's generated [L10N].
  const SimCruxThemeAppearanceStrings(this._l10n);

  final L10N _l10n;

  // --- Section composer ----------------------------------------------------

  @override
  String get sectionTitle => _l10n.settingsAppearanceSection;

  @override
  String get sectionSubtitle => _l10n.appearanceSectionSubtitle;

  @override
  String get presetSectionHeading => _l10n.appearancePresetSectionHeading;

  @override
  String get tokenOverridesSectionHeading =>
      _l10n.appearanceTokenOverridesSectionHeading;

  @override
  String get themePackBrowserSectionHeading =>
      _l10n.appearanceThemePackBrowserSectionHeading;

  // --- Preset picker -------------------------------------------------------

  @override
  String get activePresetIndicatorLabel =>
      _l10n.appearanceActivePresetIndicatorLabel;

  @override
  String get activatePresetTooltip => _l10n.appearanceActivatePresetTooltip;

  @override
  String get noPresetsAvailableMessage =>
      _l10n.appearanceNoPresetsAvailableMessage;

  @override
  String brightnessLabel({required bool isDark}) => isDark
      ? _l10n.appearanceBrightnessLabelDark
      : _l10n.appearanceBrightnessLabelLight;

  // --- Token editor --------------------------------------------------------

  @override
  String get editTokenColorTooltip => _l10n.appearanceEditTokenColorTooltip;

  @override
  String get resetTokenToDefaultTooltip =>
      _l10n.appearanceResetTokenToDefaultTooltip;

  @override
  String get emptyTokenCategoryMessage =>
      _l10n.appearanceEmptyTokenCategoryMessage;

  @override
  String collapseCategoryLabel(String categoryDisplayName) =>
      _l10n.appearanceCollapseCategoryLabel(categoryDisplayName);

  @override
  String expandCategoryLabel(String categoryDisplayName) =>
      _l10n.appearanceExpandCategoryLabel(categoryDisplayName);

  // --- Color picker --------------------------------------------------------

  @override
  String get colorPickerDialogTitle => _l10n.appearanceColorPickerDialogTitle;

  @override
  String get colorPickerHexLabel => _l10n.appearanceColorPickerHexLabel;

  @override
  String get colorPickerRgbLabel => _l10n.appearanceColorPickerRgbLabel;

  @override
  String get colorPickerHsvLabel => _l10n.appearanceColorPickerHsvLabel;

  @override
  String get colorPickerHueLabel => _l10n.appearanceColorPickerHueLabel;

  @override
  String get colorPickerSaturationLabel =>
      _l10n.appearanceColorPickerSaturationLabel;

  @override
  String get colorPickerValueLabel => _l10n.appearanceColorPickerValueLabel;

  @override
  String get colorPickerPreviewLabel => _l10n.appearanceColorPickerPreviewLabel;

  @override
  String get colorPickerOkLabel => _l10n.appearanceColorPickerOkLabel;

  @override
  String get colorPickerCancelLabel => _l10n.appearanceColorPickerCancelLabel;

  @override
  String invalidHexMessage(String input) =>
      _l10n.appearanceColorPickerInvalidHex(input);

  // --- Theme pack browser --------------------------------------------------

  @override
  String get importThemePackButtonLabel =>
      _l10n.appearanceImportThemePackButtonLabel;

  @override
  String get exportCurrentThemeButtonLabel =>
      _l10n.appearanceExportCurrentThemeButtonLabel;

  @override
  String get installedPacksHeading => _l10n.appearanceInstalledPacksHeading;

  @override
  String get noInstalledPacksMessage => _l10n.appearanceNoInstalledPacksMessage;

  @override
  String get activatePackButtonLabel => _l10n.appearanceActivatePackButtonLabel;

  @override
  String get uninstallPackButtonLabel =>
      _l10n.appearanceUninstallPackButtonLabel;

  @override
  String get confirmUninstallDialogTitle =>
      _l10n.appearanceConfirmUninstallDialogTitle;

  @override
  String confirmUninstallDialogBody(String packId) =>
      _l10n.appearanceConfirmUninstallDialogBody(packId);

  @override
  String get confirmUninstallCancelLabel =>
      _l10n.appearanceConfirmUninstallCancelLabel;

  @override
  String get confirmUninstallConfirmLabel =>
      _l10n.appearanceConfirmUninstallConfirmLabel;

  @override
  String importFailedMessage(String reason) =>
      _l10n.appearanceImportFailedMessage(reason);

  @override
  String importSucceededMessage(String packId) =>
      _l10n.appearanceImportSucceededMessage(packId);

  @override
  String exportSucceededMessage(String destinationPath) =>
      _l10n.appearanceExportSucceededMessage(destinationPath);

  @override
  String exportFailedMessage(String reason) =>
      _l10n.appearanceExportFailedMessage(reason);
}
