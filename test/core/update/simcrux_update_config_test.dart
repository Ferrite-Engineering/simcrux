// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/update/simcrux_update_config.dart';

void main() {
  group('simcruxUpdateConfig', () {
    test('names the product and points at the SimCrux endpoints', () {
      expect(simcruxUpdateConfig.productName, 'SimCrux');
      expect(
        simcruxUpdateConfig.manifestUri.toString(),
        'https://updates.simcrux.app/manifest.json',
      );
      expect(
        simcruxUpdateConfig.downloadPageUri.toString(),
        'https://simcrux.app/download',
      );
    });

    test(
      'productName is a single token so the User-Agent stays well-formed',
      () {
        expect(simcruxUpdateConfig.productName, isNot(contains(' ')));
      },
    );

    test('endpoints are https', () {
      expect(simcruxUpdateConfig.manifestUri.scheme, 'https');
      expect(simcruxUpdateConfig.downloadPageUri.scheme, 'https');
    });

    test('declares no store listings — SimCrux ships no mobile target', () {
      expect(simcruxUpdateConfig.appStoreUri, isNull);
      expect(simcruxUpdateConfig.playStoreUri, isNull);
    });

    test('checkOnMobile stays false (mobile is out of scope)', () {
      expect(simcruxUpdateConfig.checkOnMobile, isFalse);
    });

    test('every desktop platform resolves Update Now to the download page', () {
      for (final platform in const [
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        expect(
          simcruxUpdateConfig.updateTargetFor(platform),
          simcruxUpdateConfig.downloadPageUri,
          reason: 'desktop deep-links to the download page on $platform',
        );
      }
    });

    test('web resolves Update Now to the download page too', () {
      // The banner never renders on web, so this target is unreachable in
      // practice; asserting it keeps the fallback honest if that ever changes.
      expect(
        simcruxUpdateConfig.updateTargetFor(TargetPlatform.linux, isWeb: true),
        simcruxUpdateConfig.downloadPageUri,
      );
    });

    test('mobile falls back to the download page (no store listing)', () {
      expect(
        simcruxUpdateConfig.updateTargetFor(TargetPlatform.iOS),
        simcruxUpdateConfig.downloadPageUri,
      );
      expect(
        simcruxUpdateConfig.updateTargetFor(TargetPlatform.android),
        simcruxUpdateConfig.downloadPageUri,
      );
    });

    test('the beta-expiry download target is the same page', () {
      // The beta-expiry gate opens kSimcruxDownloadPageUrl directly rather
      // than reading the update config, so the two must not drift.
      expect(
        Uri.parse(kSimcruxDownloadPageUrl),
        simcruxUpdateConfig.downloadPageUri,
      );
    });
  });
}
