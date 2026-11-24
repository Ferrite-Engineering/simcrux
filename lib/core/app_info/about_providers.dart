// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io' show Platform;

import 'package:crux_app_info/crux_app_info.dart';
import 'package:crux_license/crux_license.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Short commit of a release build, passed by the release build scripts as
/// `--dart-define=BUILD_COMMIT=<sha>`. Empty in a local build.
const String kBuildGitSha = String.fromEnvironment('BUILD_COMMIT');

/// CPU architecture of a release build (`--dart-define=BUILD_ARCHITECTURE`).
const String kBuildArchitecture = String.fromEnvironment('BUILD_ARCHITECTURE');

/// Flutter SDK version of a release build
/// (`--dart-define=BUILD_FLUTTER_VERSION`).
const String kBuildFlutterVersion = String.fromEnvironment(
  'BUILD_FLUTTER_VERSION',
);

/// Four-digit year the release was built (`--dart-define=BUILD_YEAR`).
const String kBuildYear = String.fromEnvironment('BUILD_YEAR');

/// A build fact as the About dialog shows it: the value a release build
/// passed, or `dev` when a local build passed none.
String resolveBuildFact(String raw) {
  final value = raw.trim();
  return value.isEmpty ? 'dev' : value;
}

/// The copyright year: the build year a release build passed, else the
/// current year (a local build has no build date of its own).
String resolveCopyrightYear(String raw, {DateTime? now}) {
  final value = raw.trim();
  if (RegExp(r'^\d{4}$').hasMatch(value)) return value;
  return (now ?? DateTime.now()).year.toString();
}

/// Company branding shown in the SimCrux About box.
final aboutBrandingProvider = Provider<ApplicationBranding>((ref) {
  return ApplicationBranding(
    companyName: 'Ferrite Engineering',
    logoAssetPath: 'assets/branding/ferrite_engineering_logo.png',
    squareLogoAssetPath: 'assets/branding/ferrite_engineering_logo_square.png',
    copyrightYear: resolveCopyrightYear(kBuildYear),
    websiteUrl: 'https://ferriteengineering.com',
  );
});

/// Build metadata for the running SimCrux instance: version and build number
/// from `PackageInfo.fromPlatform()`, commit, architecture and Flutter
/// version from the release build's dart-defines (`dev` in a local build).
final aboutBuildInfoProvider = FutureProvider<ApplicationBuildInfo>((
  ref,
) async {
  final info = await PackageInfo.fromPlatform();
  return ApplicationBuildInfo(
    version: info.version.isNotEmpty ? info.version : 'dev',
    buildNumber: info.buildNumber.isNotEmpty ? info.buildNumber : '0',
    gitShortSha: resolveBuildFact(kBuildGitSha),
    os: _resolveOs(),
    architecture: resolveBuildFact(kBuildArchitecture),
    flutterSdkVersion: resolveBuildFact(kBuildFlutterVersion),
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
