// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license.dart';

/// The address on the educational licence the tests build.
const String kTestEduEmail = 'student@example.edu';

/// An active licence status at [tier], as a Pro overlay's licence service
/// would publish it through `licenseStatusProvider`.
CruxLicenseStatus testLicenseStatus(LicenseTier tier) => CruxLicenseStatus(
  activation: CruxLicenseActivation.active,
  grant: LicenseGrant(
    issuerId: tier == LicenseTier.edu ? kEduLicenseIssuerId : 'keygen',
    tier: tier,
    products: CruxProduct.values.toSet(),
    licenseId: 'lic-test',
    email: kTestEduEmail,
    expiry: DateTime.utc(2027, 8, 2, 12),
  ),
);

/// The statuses an export must stay unmarked under: open core and the paid
/// tiers.
final List<CruxLicenseStatus> kUnmarkedLicenseStatuses = <CruxLicenseStatus>[
  CruxLicenseStatus.openCore,
  testLicenseStatus(LicenseTier.pro),
  testLicenseStatus(LicenseTier.enterprise),
];

/// The English export mark an educational licence stamps on a SimCrux
/// report.
const String kEnglishEduExportMark =
    'Made with SimCrux Educational · Non-commercial use only';
