// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the platform-configuration facts that let this app open files and
/// reach the network at all.
///
/// Every target in the suite, open core and overlay, carries a copy. **The
/// Pro runners are what ship**, and a guard that lives only in open core
/// checks nothing a customer runs: LintCrux Pro and NetCrux Pro once
/// declared zero macOS document types while their open-core counterparts
/// declared six and five, which is the class of divergence this guard exists
/// to stop.
///
/// **The sandbox is off, deliberately.** These are Developer ID apps
/// distributed outside the Mac App Store, and they shell out to external tools
/// and bind local sockets. `com.apple.security.app-sandbox` must stay `false`;
/// flipping it on re-breaks file access, subprocess spawning and CXP in one go.
///
/// **`user-selected.read-write` is required even so.** Without it, every picker
/// invocation in a release build fails with
/// `PlatformException(ENTITLEMENT_NOT_FOUND, ...)` — while debug builds keep
/// working, because `DebugProfile.entitlements` carries broader permissions,
/// and opening a file by CLI argument keeps working too. That combination is
/// why the 2026-07-16 marketing-screenshot session was the first thing to
/// catch it: the failure is invisible unless you launch a *release* build from
/// Finder and reach for the picker.
///
/// **The network entitlements are asymmetric, and that is only safe while the
/// sandbox is off.** Every one of these files declares
/// `com.apple.security.network.server` (CXP binds a local socket) and declares
/// no `network.client` at all. Sandbox entitlements are enforced *by* the
/// sandbox, so with it disabled neither line does anything and the asymmetry
/// is inert. Enable the sandbox and it stops being inert in the worst way:
/// CXP keeps working, while the update check and telemetry upload fail
/// silently, because outbound connections are the half with no entitlement.
/// The test below ties those two facts together rather than leaving them in
/// separate assertions that each look fine alone.
///
/// `flutter create` emits none of this — it writes `app-sandbox` as `true` and
/// omits the file-access key entirely — so a future platform-directory
/// regeneration would silently revert it. Hence a static test rather than a
/// code review convention.
void main() {
  for (final profile in const ['Release', 'DebugProfile']) {
    group('macos/Runner/$profile.entitlements', () {
      late String contents;

      setUpAll(() {
        final file = File('macos/Runner/$profile.entitlements');
        expect(
          file.existsSync(),
          isTrue,
          reason:
              'macos/Runner/$profile.entitlements is missing entirely — the '
              'build cannot declare any entitlement.',
        );
        contents = file.readAsStringSync();
      });

      test('disables the app sandbox', () {
        expect(
          _boolFor(contents, 'com.apple.security.app-sandbox'),
          isFalse,
          reason:
              'The app sandbox must stay disabled. These are Developer ID '
              'builds that spawn external tools and bind local sockets; '
              'enabling the sandbox breaks file access, subprocess spawning '
              'and CXP simultaneously. `flutter create` writes this key as '
              'true, so a regenerated macos/ directory reintroduces it.',
        );
      });

      test('grants user-selected file access', () {
        expect(
          _boolFor(
            contents,
            'com.apple.security.files.user-selected.read-write',
          ),
          isTrue,
          reason:
              'file_selector needs '
              'com.apple.security.files.user-selected.read-write to open '
              'NSOpenPanel. Debug builds and CLI-argument opening both mask '
              'its absence, so nothing else catches this.',
        );
      });

      test('does not declare inbound network access without outbound', () {
        final server = _boolFor(
          contents,
          'com.apple.security.network.server',
        );
        final client = _boolFor(
          contents,
          'com.apple.security.network.client',
        );
        final sandboxed =
            _boolFor(contents, 'com.apple.security.app-sandbox') ?? false;

        // Inert while the sandbox is off, which is the state the test above
        // pins. This assertion exists for the day somebody changes that: a
        // sandboxed build with server-but-not-client keeps CXP working and
        // silently loses the update check and telemetry upload, and nothing
        // in the app reports it.
        if (sandboxed && server == true) {
          expect(
            client,
            isTrue,
            reason:
                'The sandbox is enabled and this build declares '
                'network.server without network.client. Inbound CXP will '
                'work and every outbound connection — update check, '
                'telemetry, issue reporter — will fail with no error the '
                'user can see. Add network.client, or turn the sandbox back '
                'off.',
          );
        }
      });

      test('declares exactly the pinned entitlement set', () {
        final expected = _pinnedEntitlements[profile]!;
        expect(
          _entitlements(contents),
          expected,
          reason:
              'macos/Runner/$profile.entitlements no longer matches the '
              'pinned set in this file. Every key is pinned, not only the '
              'ones asserted above: a Hardened Runtime exception (JIT, '
              'unsigned executable memory, disabled library validation) '
              'added here would otherwise ship signed and notarized with '
              'nothing noticing. If the change is intended, change the '
              'pinned set with it and say why.',
        );
        expect(
          RegExp('<key>').allMatches(contents).length,
          expected.length,
          reason:
              'A key is declared twice, or a <key> is followed by something '
              'this guard cannot read as a value.',
        );
      });
    });
  }

  // This target ships no Android runner, so there is no manifest to check.
  // Asserting the premise rather than skipping: if an android/ directory
  // appears, this fails and names the check that has to come with it.
  test('this target still ships no Android runner', () {
    expect(
      Directory('android').existsSync(),
      isFalse,
      reason:
          'An Android runner appeared. Add the INTERNET-in-main-manifest '
          'assertion from wavecrux/test/static/macos_entitlements_test.dart — '
          'the Flutter template declares that permission for debug and '
          'profile only, so a release build loses networking with no error.',
    );
  });
}

/// The COMPLETE entitlement set each profile may declare: every key and its
/// value. The tests above each guard one fact; this pins the whole file, so
/// an entitlement nobody wrote a test for cannot ride along unnoticed.
///
/// Release still carries `com.apple.security.cs.allow-jit`, and that is a
/// deliberate hold, not an endorsement. The release build is AOT-compiled
/// Dart and nothing found in the shipped binaries generates code at run
/// time, so the key is probably removable. "Probably" is not the bar for a
/// signed, notarized build the kernel kills on launch if it is wrong, and
/// that failure class is real here: a Dart AOT command-line executable
/// signed with the Hardened Runtime is SIGKILLed at launch unless it carries
/// `allow-unsigned-executable-memory`, and `allow-jit` does not substitute
/// for it. Remove this key only together with a launch of a
/// Hardened-Runtime-signed release build that does not carry it.
/// DebugProfile keeps it because the Dart VM JIT-compiles in debug builds.
const _pinnedEntitlements = <String, Map<String, Object>>{
  'Release': {
    'com.apple.security.app-sandbox': false,
    'com.apple.security.cs.allow-jit': true,
    'com.apple.security.network.server': true,
    'com.apple.security.files.user-selected.read-write': true,
  },
  'DebugProfile': {
    'com.apple.security.app-sandbox': false,
    'com.apple.security.cs.allow-jit': true,
    'com.apple.security.network.server': true,
    'com.apple.security.files.user-selected.read-write': true,
  },
};

/// Every `<key>` in [plist] mapped to its value: `true` or `false` for a
/// boolean, the raw element for anything else, so a non-boolean entitlement
/// (an array of groups, say) still takes part in the comparison instead of
/// being skipped as a key nothing checks.
Map<String, Object> _entitlements(String plist) {
  final result = <String, Object>{};
  final pair = RegExp(r'<key>([^<]+)</key>\s*(<[^>]+>)');
  for (final match in pair.allMatches(plist)) {
    final element = match.group(2)!.replaceAll(RegExp(r'\s'), '');
    final Object value;
    if (element == '<true/>') {
      value = true;
    } else if (element == '<false/>') {
      value = false;
    } else {
      value = element;
    }
    result[match.group(1)!] = value;
  }
  return result;
}

/// Reads the boolean value that follows [key] in a plist, or `null` if the key
/// is absent.
///
/// Deliberately not a full plist parse: matching `<key>` to the next
/// `<true/>`/`<false/>` is enough for these flat, boolean-valued files, and
/// it keeps the guard dependency-free. Whitespace between the two tags varies
/// by editor, so it is matched loosely.
bool? _boolFor(String plist, String key) {
  final match = RegExp(
    '<key>${RegExp.escape(key)}</key>\\s*<(true|false)\\s*/>',
  ).firstMatch(plist);
  return match == null ? null : match.group(1) == 'true';
}
