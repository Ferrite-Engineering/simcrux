// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:simcrux/core/app_info/about_providers.dart';

void main() {
  group('resolveBuildFact', () {
    test('keeps a value a release build passed', () {
      expect(resolveBuildFact('abc1234'), 'abc1234');
      expect(resolveBuildFact('  arm64 '), 'arm64');
    });

    test('reads dev when nothing was passed', () {
      expect(resolveBuildFact(''), 'dev');
      expect(resolveBuildFact('   '), 'dev');
    });
  });

  group('resolveCopyrightYear', () {
    test('uses the build year a release build passed', () {
      expect(resolveCopyrightYear('2026'), '2026');
      expect(resolveCopyrightYear(' 2027 ', now: DateTime(2030)), '2027');
    });

    test('falls back to the current year, never a literal', () {
      expect(resolveCopyrightYear('', now: DateTime(2031)), '2031');
      expect(resolveCopyrightYear('twenty', now: DateTime(2031)), '2031');
      expect(resolveCopyrightYear('26', now: DateTime(2031)), '2031');
    });
  });

  group('providers in a local build (no dart-defines)', () {
    setUp(() {
      PackageInfo.setMockInitialValues(
        appName: 'SimCrux',
        packageName: 'app.simcrux',
        version: '1.2.0',
        buildNumber: '7',
        buildSignature: '',
      );
    });

    test('build info reads dev for commit, architecture and Flutter', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final info = await container.read(aboutBuildInfoProvider.future);
      expect(info.version, '1.2.0');
      expect(info.buildNumber, '7');
      expect(info.gitShortSha, 'dev');
      expect(info.architecture, 'dev');
      expect(info.flutterSdkVersion, 'dev');
    });

    test('branding carries the current year', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        container.read(aboutBrandingProvider).copyrightYear,
        DateTime.now().year.toString(),
      );
    });
  });
}
