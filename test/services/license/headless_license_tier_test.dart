// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_license/crux_license_core.dart';
import 'package:crux_policy/crux_policy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/services/license/headless_license_tier.dart';

import 'headless_license_fixtures.dart';

/// A validator that answers from a table keyed by the credential text, so
/// the resolver's source order and outcome mapping are testable without a
/// signed credential.
class _TableValidator implements LicenseValidator {
  _TableValidator(this.outcomes);

  final Map<String, LicenseValidation> outcomes;
  final List<String> seen = <String>[];

  @override
  String get name => 'table';

  @override
  Future<LicenseValidation> validate(
    String? rawCredential, {
    DateTime? now,
    String? fingerprint,
  }) async {
    seen.add(rawCredential ?? '');
    return outcomes[rawCredential?.trim()] ??
        const LicenseRejected(LicenseRejection.malformed, 'not in table');
  }
}

LicenseGrant _grant(LicenseTier tier, {DateTime? expiry}) => LicenseGrant(
  issuerId: 'test',
  tier: tier,
  products: const {CruxProduct.simCrux},
  expiry: expiry,
);

PolicyLoadResult _policy(String json) =>
    PolicyLoadResult(document: PolicyDocument.parse(json));

PolicyLoadResult _noPolicy() =>
    const PolicyLoadResult(document: PolicyDocument.absent);

void main() {
  final now = DateTime.utc(2027, 3);
  final pro = _grant(LicenseTier.pro);

  HeadlessLicenseTierResolver resolver({
    Map<String, LicenseValidation> outcomes = const {},
    Map<String, String> environment = const {},
    PolicyLoadResult Function()? loadPolicy,
    Map<String, String> files = const {},
  }) => HeadlessLicenseTierResolver(
    validator: _TableValidator(outcomes),
    environment: environment,
    loadPolicy: loadPolicy ?? _noPolicy,
    readFile: (path) async {
      final contents = files[path];
      if (contents == null) {
        throw FileSystemException('No such file', path);
      }
      return contents;
    },
    clock: () => now,
  );

  group('HeadlessLicenseTierResolver', () {
    test('no source anywhere is Open Core, with nothing to say', () async {
      final r = await resolver().resolve();
      expect(r.tier, LicenseTier.openCore);
      expect(r.notes, isEmpty);
    });

    test('--license-file is validated and its tier used', () async {
      final r = await resolver(
        outcomes: {'PRO-CRED': LicenseAccepted(pro)},
        files: {'/ci/simcrux.lic': 'PRO-CRED\n'},
      ).resolve(licenseFilePath: '/ci/simcrux.lic');
      expect(r.tier, LicenseTier.pro);
      expect(r.notes.single, contains('Pro'));
      expect(r.notes.single, contains('/ci/simcrux.lic'));
    });

    test('the flag wins over the environment and the policy file', () async {
      final r = await resolver(
        outcomes: {
          'FLAG': LicenseAccepted(_grant(LicenseTier.enterprise)),
          'ENV': LicenseAccepted(pro),
        },
        environment: {kSimcruxLicenseFileEnvVar: '/env.lic'},
        files: {'/flag.lic': 'FLAG', '/env.lic': 'ENV'},
        loadPolicy: () =>
            _policy('{"schema":1,"suite":{"license":{"key":"POLICY"}}}'),
      ).resolve(licenseFilePath: '/flag.lic');
      expect(r.tier, LicenseTier.enterprise);
    });

    test('SIMCRUX_LICENSE_FILE is used when no flag is given', () async {
      final r = await resolver(
        outcomes: {'ENV': LicenseAccepted(_grant(LicenseTier.edu))},
        environment: {kSimcruxLicenseFileEnvVar: '/env.lic'},
        files: {'/env.lic': 'ENV'},
      ).resolve();
      expect(r.tier, LicenseTier.edu);
    });

    test('an inline policy license is used last', () async {
      final r = await resolver(
        outcomes: {'POLICY': LicenseAccepted(pro)},
        loadPolicy: () =>
            _policy('{"schema":1,"suite":{"license":{"key":"POLICY"}}}'),
      ).resolve();
      expect(r.tier, LicenseTier.pro);
      expect(r.notes.single, contains('policy file'));
    });

    test('a policy license file is read from its path', () async {
      final r = await resolver(
        outcomes: {'SHARED': LicenseAccepted(pro)},
        files: {'/share/crux.lic': 'SHARED'},
        loadPolicy: () => _policy(
          '{"schema":1,"suite":{"license":{"file":"/share/crux.lic"}}}',
        ),
      ).resolve();
      expect(r.tier, LicenseTier.pro);
    });

    test('an unreadable policy license file degrades to Open Core with a '
        'note', () async {
      final r = await resolver(
        loadPolicy: () => _policy(
          '{"schema":1,"suite":{"license":{"file":"/offline/crux.lic"}}}',
        ),
      ).resolve();
      expect(r.tier, LicenseTier.openCore);
      expect(r.notes.single, contains('cannot read'));
    });

    test('an unreadable --license-file throws', () async {
      expect(
        () => resolver().resolve(licenseFilePath: '/missing.lic'),
        throwsA(
          isA<HeadlessLicenseException>().having(
            (e) => e.message,
            'message',
            contains('/missing.lic'),
          ),
        ),
      );
    });

    test('an unreadable SIMCRUX_LICENSE_FILE throws', () async {
      expect(
        () => resolver(
          environment: {kSimcruxLicenseFileEnvVar: '/gone.lic'},
        ).resolve(),
        throwsA(isA<HeadlessLicenseException>()),
      );
    });

    test('an empty --license-file throws', () async {
      expect(
        () => resolver(
          files: {'/empty.lic': '  \n'},
        ).resolve(licenseFilePath: '/empty.lic'),
        throwsA(isA<HeadlessLicenseException>()),
      );
    });

    test('a rejected credential runs as Open Core and says why', () async {
      final r = await resolver(
        files: {'/bad.lic': 'TAMPERED'},
        outcomes: {
          'TAMPERED': const LicenseRejected(
            LicenseRejection.untrustedIssuer,
            'no trusted issuer',
          ),
        },
      ).resolve(licenseFilePath: '/bad.lic');
      expect(r.tier, LicenseTier.openCore);
      expect(r.notes.single, contains('untrustedIssuer'));
      expect(r.notes.single, contains('Open Core'));
    });

    test('an expired license keeps its tier inside the grace period', () async {
      final r = await resolver(
        files: {'/l.lic': 'EXPIRED'},
        outcomes: {
          'EXPIRED': LicenseExpired(
            _grant(
              LicenseTier.pro,
              expiry: now.subtract(const Duration(days: 5)),
            ),
          ),
        },
      ).resolve(licenseFilePath: '/l.lic');
      expect(r.tier, LicenseTier.pro);
      expect(r.notes.single, contains('grace period ends'));
    });

    test('an expired license past its grace period is Open Core', () async {
      final r = await resolver(
        files: {'/l.lic': 'EXPIRED'},
        outcomes: {
          'EXPIRED': LicenseExpired(
            _grant(
              LicenseTier.pro,
              expiry: now.subtract(const Duration(days: 90)),
            ),
          ),
        },
      ).resolve(licenseFilePath: '/l.lic');
      expect(r.tier, LicenseTier.openCore);
      expect(r.notes.single, contains('past its grace period'));
    });

    test('a refused policy file is reported and ignored', () async {
      final r = await resolver(
        loadPolicy: () => const PolicyLoadResult(
          document: PolicyDocument.absent,
          rejection: PolicyRejection.badSignature,
          sourcePath: '/etc/edacrux/.crux-policy.json',
          detail: 'signature does not verify',
        ),
      ).resolve();
      expect(r.tier, LicenseTier.openCore);
      expect(r.notes.single, contains('badSignature'));
    });

    test(
      'garbage from --license-file is rejected by the real validator',
      () async {
        final r = await HeadlessLicenseTierResolver(
          environment: const {},
          loadPolicy: _noPolicy,
          readFile: (_) async => 'not a license at all',
        ).resolve(licenseFilePath: '/garbage.lic');
        expect(r.tier, LicenseTier.openCore);
        expect(r.notes.single, contains('malformed'));
      },
    );
  });

  // A machine file — what offline activation issues — resolves only on the
  // machine whose fingerprint it names, and a validation that names no
  // machine is refused as the wrong machine. These run the real validator over
  // signed fixtures, so they fail if the resolver stops telling it which
  // machine this is, not merely if a stub stops being called.
  group('a signed machine file, resolved headless', () {
    late Directory home;
    late Map<String, String> env;

    setUp(() {
      home = Directory.systemTemp.createTempSync('simcrux_headless_fp_');
      // Every platform's variable, so both the shared fingerprint file and
      // the legacy per-product one resolve under the temp directory whichever
      // OS runs this.
      env = <String, String>{
        'HOME': home.path,
        'APPDATA': home.path,
        'LOCALAPPDATA': home.path,
        'XDG_DATA_HOME': home.path,
      };
    });
    tearDown(() => home.deleteSync(recursive: true));

    // The suite's shared file, which every EDACrux product on this account
    // reads and writes.
    File sharedFile() => File(
      '${cruxLicenseDirectory(environment: env)}'
      '${Platform.pathSeparator}install.fingerprint',
    );

    // The file earlier SimCrux releases wrote, before the fingerprint was
    // shared.
    File legacyFile() =>
        File(legacyInstallFingerprintPath('simcrux', environment: env));

    void record(File file, String value) {
      file
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('$value\n');
    }

    HeadlessLicenseTierResolver signed(
      String credential, {
      Map<String, String>? environment,
    }) => HeadlessLicenseTierResolver(
      validator: fixtureValidator(),
      environment: environment ?? env,
      loadPolicy: _noPolicy,
      readFile: (_) async => credential,
      clock: () => now,
    );

    test(
      'resolves to its tier on the machine whose shared fingerprint it names',
      () async {
        record(sharedFile(), fixtureBoundFingerprint);
        final r = await signed(
          fixtureMachineFile,
        ).resolve(licenseFilePath: '/ci/machine.lic');
        expect(r.tier, LicenseTier.pro, reason: r.notes.join('\n'));
        expect(r.notes.single, contains('Pro from license file'));
      },
    );

    test('resolves on a machine that still has only the legacy SimCrux file, '
        'by adopting its value into the shared file', () async {
      record(legacyFile(), fixtureBoundFingerprint);
      final r = await signed(
        fixtureMachineFile,
      ).resolve(licenseFilePath: '/ci/machine.lic');
      expect(r.tier, LicenseTier.pro, reason: r.notes.join('\n'));
      expect(sharedFile().readAsStringSync().trim(), fixtureBoundFingerprint);
      // Left in place, so a downgrade still finds its fingerprint.
      expect(legacyFile().readAsStringSync().trim(), fixtureBoundFingerprint);
    });

    test('the shared file wins over the legacy one', () async {
      record(sharedFile(), 'another-install-fp-0002');
      record(legacyFile(), fixtureBoundFingerprint);
      final r = await signed(
        fixtureMachineFile,
      ).resolve(licenseFilePath: '/ci/machine.lic');
      expect(r.tier, LicenseTier.openCore);
      expect(r.notes.single, contains('wrongMachine'));
    });

    test('is refused on a machine with another fingerprint', () async {
      record(sharedFile(), 'another-install-fp-0002');
      final r = await signed(
        fixtureMachineFile,
      ).resolve(licenseFilePath: '/ci/machine.lic');
      expect(r.tier, LicenseTier.openCore);
      expect(r.notes.single, contains('wrongMachine'));
      expect(r.notes.single, contains('another machine'));
    });

    test(
      'is refused where this machine has no fingerprint and none can be '
      'recorded',
      () async {
        // No home variable at all: there is nowhere to read one from or mint
        // one into.
        final r = await signed(
          fixtureMachineFile,
          environment: const <String, String>{},
        ).resolve(licenseFilePath: '/ci/machine.lic');
        expect(r.tier, LicenseTier.openCore);
        expect(r.notes.single, contains('wrongMachine'));
      },
    );

    test('mints a build agent with neither file a fingerprint in the shared '
        'file on first use and keeps it, so it has an identity to issue a '
        'machine file for', () async {
      expect(sharedFile().existsSync(), isFalse);
      await signed(
        fixtureMachineFile,
      ).resolve(licenseFilePath: '/ci/machine.lic');
      final minted = sharedFile().readAsStringSync().trim();
      expect(minted, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
      expect(legacyFile().existsSync(), isFalse);

      await signed(
        fixtureMachineFile,
      ).resolve(licenseFilePath: '/ci/machine.lic');
      expect(sharedFile().readAsStringSync().trim(), minted);
    });

    test('a licence file names no machine: it resolves without a fingerprint, '
        'and creates none', () async {
      final r = await signed(
        fixtureLicenseFile,
      ).resolve(licenseFilePath: '/ci/license.lic');
      expect(r.tier, LicenseTier.pro, reason: r.notes.join('\n'));
      expect(sharedFile().existsSync(), isFalse);
    });
  });
}
