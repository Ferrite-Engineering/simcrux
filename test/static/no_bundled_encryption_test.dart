// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the claim the suite's export-control position rests on:
/// **open core calls TLS and hashes; it does not encrypt.**
///
/// The suite's export-control position answers "which products implement
/// encryption?" with *WaveCrux Pro only*, and "which do not?" with NetCrux,
/// SimCrux and LintCrux in both tiers, WaveCrux open core, and every
/// crux-shared package. That is a claim about every target in the suite, so
/// every target tests it. This is SimCrux open core's copy.
///
/// Two separate things depend on the claim staying true:
///
/// 1. **The App Store declaration.** WaveCrux's `ios/Runner/Info.plist`
///    declares `ITSAppUsesNonExemptEncryption` as `false`, and the store
///    builds are open core. This target ships no iOS runner, so it carries no declaration of its own — but a cipher reaching it through crux-shared would reach WaveCrux too.
/// 2. **The open-core flip.** Publishing encryption *source code* triggers a
///    notification obligation (EAR §742.15(b)) that publishing TLS-calling code
///    does not. Open core is publishable without one only while it contains no
///    cipher.
///
/// Neither failure is loud. The notification obligation has no build-time
/// symptom at all, and a transitive pull-up through some unrelated new package
/// would produce no warning whatsoever. Hence a static guard.
///
/// **Hashing is deliberately allowed.** `crypto` (SHA/HMAC) is already a
/// transitive dependency and stays one — hashing is not encryption. So is
/// calling the platform's HTTPS stack, which is what every network path here
/// does.
///
/// If a cipher genuinely belongs here, the export-control position is what
/// needs revisiting first — do not simply delete an entry from the list below.
void main() {
  test('SimCrux open core bundles no encryption implementation', () {
    final lock = File('pubspec.lock');
    expect(
      lock.existsSync(),
      isTrue,
      reason:
          'pubspec.lock is missing, so this guard cannot see the resolved '
          'dependency set. The lock is tracked on purpose; restore it.',
    );

    final resolved = _resolvedPackages(lock.readAsStringSync());
    final found = _encryptionPackages.where(resolved.contains).toList();

    expect(
      found,
      isEmpty,
      reason:
          'This target resolved an encryption package: ${found.join(', ')}.\n\n'
          'Encryption implementations belong only in WaveCrux Pro, the one '
          'target in the suite that declares one. Landing one here contradicts '
          "the suite's export-control position, and publishing this source "
          'acquires an EAR §742.15(b) notification obligation this repo does '
          'not otherwise have.\n\n'
          'This fires for transitive pull-ups too, which is the case nothing '
          'else would catch. Check `flutter pub deps` for who wants it.',
    );
  });

  test('this product still ships no iOS runner', () {
    // The plist half of WaveCrux's guard has nothing to assert here, and a
    // skipped test would quietly stop guarding the day that changes. So assert
    // the premise instead: if an ios/ runner appears, this fails and points at
    // the declaration that now has to be made.
    expect(
      Directory('ios').existsSync(),
      isFalse,
      reason:
          'An iOS runner appeared. Add the ITSAppUsesNonExemptEncryption=false '
          'assertion from wavecrux/test/static/no_bundled_encryption_test.dart '
          'to this file — App Store Connect prompts for that answer at every '
          'submission when the key is absent.',
    );
  });
}

/// Packages that implement a cipher, as opposed to hashing or calling the
/// platform's TLS.
///
/// Not exhaustive — no fixed list can be — but it covers what a Flutter project
/// realistically reaches for, including the maintained forks that appeared after
/// `cryptography` went quiet. Kept byte-identical to WaveCrux's copy on purpose:
/// a per-repo list that drifts is a per-repo answer to a suite-wide question.
const _encryptionPackages = <String>{
  'cryptography',
  'cryptography_flutter',
  'cryptography_flutter_plus',
  'cryptography_plus',
  'encrypt',
  'flutter_sodium',
  'libsodium',
  'pointycastle',
  'sodium',
  'sodium_libs',
  'steel_crypt',
  'webcrypto',
};

/// Every package name in a `pubspec.lock`, regardless of dependency kind.
///
/// Transitive entries matter as much as direct ones here: the failure this
/// guards against is a cipher arriving as somebody else's dependency, which is
/// invisible in `pubspec.yaml`. Package entries are the two-space-indented keys
/// under `packages:`; the file's other top-level sections (`sdks:`) have no
/// such nesting to confuse.
Set<String> _resolvedPackages(String lock) => RegExp(
  r'^  ([a-z_0-9]+):$',
  multiLine: true,
).allMatches(lock).map((m) => m.group(1)!).toSet();
