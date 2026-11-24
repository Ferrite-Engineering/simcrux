// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// The headless licence resolver the desktop app's `--ci` path reads.
///
/// The resolver itself is `crux_license`'s [HeadlessLicenseTierResolver],
/// the one every EDACrux headless binary and MCP server uses: `--license-file`,
/// then `SIMCRUX_LICENSE_FILE`, then the organization policy file's
/// `license`, validated offline. Only the provider is SimCrux's own.
library;

import 'package:crux_license/crux_license_core.dart';
import 'package:crux_license/crux_license_headless.dart';
import 'package:riverpod/riverpod.dart';

/// The resolver the desktop app's `--ci` path uses. Overridden in tests.
///
/// `package:riverpod` rather than `flutter_riverpod`, so this file stays out
/// of Flutter, as the headless resolver does.
final Provider<HeadlessLicenseTierResolver>
headlessLicenseTierResolverProvider = Provider<HeadlessLicenseTierResolver>(
  (_) => HeadlessLicenseTierResolver(product: CruxProduct.simCrux),
);
