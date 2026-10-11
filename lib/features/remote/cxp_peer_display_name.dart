// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license.dart';

/// The name a user reads for the CXP wire product id [productName]:
/// `wavecrux` is WaveCrux. A peer outside the suite keeps the name it
/// announced.
String cxpPeerDisplayName(String productName) {
  for (final product in CruxProduct.values) {
    if (product.name.toLowerCase() == productName) return product.displayName;
  }
  return productName;
}
