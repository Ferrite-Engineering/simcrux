// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io' show Platform;

import 'package:crux_app_info/crux_app_info.dart';
import 'package:crux_license/crux_license.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Company branding shown in the SimCrux About box.
final aboutBrandingProvider = Provider<ApplicationBranding>((ref) {
  return const ApplicationBranding(
    companyName: 'Ferrite Engineering',
    logoAssetPath: 'assets/branding/ferrite_engineering_logo.png',
    squareLogoAssetPath: 'assets/branding/ferrite_engineering_logo_square.png',
    copyrightYear: '2025',
    websiteUrl: 'https://ferriteengineering.com',
  );
});

/// Build metadata for the running SimCrux instance, sourced from
/// `PackageInfo.fromPlatform()` plus best-effort platform introspection.
final aboutBuildInfoProvider = FutureProvider<ApplicationBuildInfo>((
  ref,
) async {
  final info = await PackageInfo.fromPlatform();
  return ApplicationBuildInfo(
    version: info.version.isNotEmpty ? info.version : 'dev',
    buildNumber: info.buildNumber.isNotEmpty ? info.buildNumber : '0',
    gitShortSha: 'dev',
    os: _resolveOs(),
    architecture: 'unknown',
    flutterSdkVersion: 'unknown',
    dartSdkVersion: _dartVersion(),
  );
});

String _dartVersion() {
  if (kIsWeb) return 'unknown';
  final v = Platform.version;
  final space = v.indexOf(' ');
  return space > 0 ? v.substring(0, space) : v;
}

String _resolveOs() {
  if (kIsWeb) return 'Web';
  try {
    if (Platform.isMacOS) return 'macOS ${Platform.operatingSystemVersion}';
    if (Platform.isLinux) return 'Linux ${Platform.operatingSystemVersion}';
    if (Platform.isWindows) return 'Windows ${Platform.operatingSystemVersion}';
    if (Platform.isIOS) return 'iOS ${Platform.operatingSystemVersion}';
    if (Platform.isAndroid) return 'Android ${Platform.operatingSystemVersion}';
  } on Exception catch (_) {}
  return 'unknown';
}

/// Resolves the user-visible edition label for the current license tier.
///
/// Returns the localized "Open Core" label for [LicenseTier.openCore]; the
/// About dialog hides the edition chip when the label equals that value.
String aboutEditionLabel(WidgetRef ref, L10N l10n) {
  final tier = ref.read(licenseTierProvider);
  return switch (tier) {
    LicenseTier.openCore => l10n.aboutEditionOpenCore,
    LicenseTier.edu => 'EDU',
    LicenseTier.pro => 'Pro',
    LicenseTier.enterprise => 'Enterprise',
  };
}
