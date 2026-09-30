// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// Signed licence fixtures for the headless resolver's machine-file tests.
///
/// **Nothing here is signed by the production key.** Keygen holds that key and
/// nothing in this repository could sign with it. These were minted once from
/// the same throwaway seed `crux_license`'s own validator tests use (32 bytes
/// of `7`), with that package's test-only signer, and are checked by the real
/// `CruxLicenseValidator` configured with [fixtureIssuerPublicKey] — so a
/// production build refuses every one of them as `untrustedIssuer`.
///
/// Committed rather than minted per run because signing needs an Ed25519
/// implementation this package deliberately does not carry: shipped code may
/// verify a signature and never make one.
///
/// Both credentials grant SimCrux Pro through embedded entitlements, on the
/// fixture account below, and expire long after any clock these tests use.
library;

import 'package:crux_license/crux_license_core.dart';

/// The account both fixtures name.
const String fixtureAccountId = 'acc0acc0-0000-4000-8000-000000000001';

/// The public half of the throwaway signing pair.
const List<int> fixtureIssuerPublicKey = <int>[
  234, 74, 108, 99, 226, 156, 82, 10, 190, 245, 80, 123, 19, 46, 197, 249, //
  149, 71, 118, 174, 190, 190, 123, 146, 66, 30, 234, 105, 20, 70, 210, 44,
];

/// The fingerprint [fixtureMachineFile] was checked out for.
const String fixtureBoundFingerprint = 'this-install-fp-0001';

/// A validator that trusts only the fixture issuer, as SimCrux.
CruxLicenseValidator fixtureValidator() => CruxLicenseValidator(
  product: CruxProduct.simCrux,
  issuers: const <LicenseIssuer>[
    KeygenLicenseIssuer(
      accountId: fixtureAccountId,
      verifyKey: fixtureIssuerPublicKey,
      policies: <String, KeygenPolicy>{},
    ),
  ],
);

/// A Keygen machine file granting SimCrux Pro, bound to
/// [fixtureBoundFingerprint].
const String fixtureMachineFile = '''
-----BEGIN MACHINE FILE-----
eyJlbmMiOiJleUp0WlhSaElqcDdJbWx6YzNWbFpDSTZJakl3TWpZdE1EZ3RNREZV
TURBNk1EQTZNREF1TURBd1dpSXNJblIwYkNJNk1IMHNJbVJoZEdFaU9uc2lkSGx3
WlNJNkltMWhZMmhwYm1Weklpd2lhV1FpT2lKdFlXTm9NREF3TUMwd01EQXdMVFF3
TURBdE9EQXdNQzB3TURBd01EQXdNREF3TURFaUxDSmhkSFJ5YVdKMWRHVnpJanA3
SW1acGJtZGxjbkJ5YVc1MElqb2lkR2hwY3kxcGJuTjBZV3hzTFdad0xUQXdNREVp
TENKdVlXMWxJam9pWTJrdFlXZGxiblF0TURFaUxDSndiR0YwWm05eWJTSTZJbXhw
Ym5WNEluMHNJbkpsYkdGMGFXOXVjMmhwY0hNaU9uc2lZV05qYjNWdWRDSTZleUpr
WVhSaElqcDdJblI1Y0dVaU9pSmhZMk52ZFc1MGN5SXNJbWxrSWpvaVlXTmpNR0Zq
WXpBdE1EQXdNQzAwTURBd0xUZ3dNREF0TURBd01EQXdNREF3TURBeEluMTlMQ0pz
YVdObGJuTmxJanA3SW1SaGRHRWlPbnNpZEhsd1pTSTZJbXhwWTJWdWMyVnpJaXdp
YVdRaU9pSnNhV013TURBd01DMHdNREF3TFRRd01EQXRPREF3TUMwd01EQXdNREF3
TURBd01ERWlmWDE5ZlN3aWFXNWpiSFZrWldRaU9sdDdJblI1Y0dVaU9pSnNhV05s
Ym5ObGN5SXNJbWxrSWpvaWJHbGpNREF3TURBdE1EQXdNQzAwTURBd0xUZ3dNREF0
TURBd01EQXdNREF3TURBeElpd2lZWFIwY21saWRYUmxjeUk2ZXlKamNtVmhkR1Zr
SWpvaU1qQXlOaTB3T0Mwd01WUXdNRG93TURvd01DNHdNREJhSWl3aVpYaHdhWEo1
SWpvaU1qQTVPUzB3TVMwd01WUXdNRG93TURvd01DNHdNREJhSWl3aWJXRjRUV0Zq
YUdsdVpYTWlPalVzSW0xbGRHRmtZWFJoSWpwN0ltVnRZV2xzSWpvaVluVjVaWEpB
WlhoaGJYQnNaUzVqYjIwaWZYMHNJbkpsYkdGMGFXOXVjMmhwY0hNaU9uc2lZV05q
YjNWdWRDSTZleUprWVhSaElqcDdJblI1Y0dVaU9pSmhZMk52ZFc1MGN5SXNJbWxr
SWpvaVlXTmpNR0ZqWXpBdE1EQXdNQzAwTURBd0xUZ3dNREF0TURBd01EQXdNREF3
TURBeEluMTlMQ0p3YjJ4cFkza2lPbnNpWkdGMFlTSTZleUowZVhCbElqb2ljRzlz
YVdOcFpYTWlMQ0pwWkNJNkluQXdNREF3TURBd0xUQXdNREF0TkRBd01DMDRNREF3
TFRBd01EQXdNREF3TURBd1l5SjlmWDE5TEhzaWRIbHdaU0k2SW1WdWRHbDBiR1Z0
Wlc1MGN5SXNJbWxrSWpvaVpXNTBMVk5KVFVOU1ZWZ2lMQ0poZEhSeWFXSjFkR1Z6
SWpwN0ltTnZaR1VpT2lKVFNVMURVbFZZSW4xOUxIc2lkSGx3WlNJNkltVnVkR2ww
YkdWdFpXNTBjeUlzSW1sa0lqb2laVzUwTFZSSlJWSmZVRkpQSWl3aVlYUjBjbWxp
ZFhSbGN5STZleUpqYjJSbElqb2lWRWxGVWw5UVVrOGlmWDFkZlEiLCJzaWciOiI1
STdqaE1QWDBOQ0Y0UUZZeFJGZURUckVmX2N6cHI2QlNSdmtFRHJJZVozX0s3Vjgt
ZFl6OEtlcjRkcnRUbVFSTkI4MENGYmlBUnVWUU9XT0NXbndCdyIsImFsZyI6ImJh
c2U2NCtlZDI1NTE5In0=
-----END MACHINE FILE-----
''';

/// A Keygen licence file granting SimCrux Pro. It names no machine.
const String fixtureLicenseFile = '''
-----BEGIN LICENSE FILE-----
eyJlbmMiOiJleUp0WlhSaElqcDdJbWx6YzNWbFpDSTZJakl3TWpZdE1EZ3RNREZV
TURBNk1EQTZNREF1TURBd1dpSXNJblIwYkNJNk1IMHNJbVJoZEdFaU9uc2lkSGx3
WlNJNklteHBZMlZ1YzJWeklpd2lhV1FpT2lKc2FXTXdNREF3TUMwd01EQXdMVFF3
TURBdE9EQXdNQzB3TURBd01EQXdNREF3TURFaUxDSmhkSFJ5YVdKMWRHVnpJanA3
SW1OeVpXRjBaV1FpT2lJeU1ESTJMVEE0TFRBeFZEQXdPakF3T2pBd0xqQXdNRm9p
TENKbGVIQnBjbmtpT2lJeU1EazVMVEF4TFRBeFZEQXdPakF3T2pBd0xqQXdNRm9p
TENKdFlYaE5ZV05vYVc1bGN5STZOU3dpYldWMFlXUmhkR0VpT25zaVpXMWhhV3dp
T2lKaWRYbGxja0JsZUdGdGNHeGxMbU52YlNKOWZTd2ljbVZzWVhScGIyNXphR2x3
Y3lJNmV5SmhZMk52ZFc1MElqcDdJbVJoZEdFaU9uc2lkSGx3WlNJNkltRmpZMjkx
Ym5Seklpd2lhV1FpT2lKaFkyTXdZV05qTUMwd01EQXdMVFF3TURBdE9EQXdNQzB3
TURBd01EQXdNREF3TURFaWZYMHNJbkJ2YkdsamVTSTZleUprWVhSaElqcDdJblI1
Y0dVaU9pSndiMnhwWTJsbGN5SXNJbWxrSWpvaWNEQXdNREF3TURBdE1EQXdNQzAw
TURBd0xUZ3dNREF0TURBd01EQXdNREF3TURCakluMTlmWDBzSW1sdVkyeDFaR1Zr
SWpwYmV5SjBlWEJsSWpvaVpXNTBhWFJzWlcxbGJuUnpJaXdpYVdRaU9pSmxiblF0
VTBsTlExSlZXQ0lzSW1GMGRISnBZblYwWlhNaU9uc2lZMjlrWlNJNklsTkpUVU5T
VlZnaWZYMHNleUowZVhCbElqb2laVzUwYVhSc1pXMWxiblJ6SWl3aWFXUWlPaUps
Ym5RdFZFbEZVbDlRVWs4aUxDSmhkSFJ5YVdKMWRHVnpJanA3SW1OdlpHVWlPaUpV
U1VWU1gxQlNUeUo5ZlYxOSIsInNpZyI6ImpLMDJNQVF6WjVUV0hJc3FhQmNzSk5Q
VndNVG1TN0RwWkpqTnJ3eEhLNmR6dVlHSVk0MGNDdENwNlF3bXgzVXVUY2NtaElN
eG1scjdKWFZuaG5mRURRIiwiYWxnIjoiYmFzZTY0K2VkMjU1MTkifQ==
-----END LICENSE FILE-----
''';
