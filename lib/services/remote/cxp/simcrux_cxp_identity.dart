// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/core/app_info/build_info.dart';

/// Short product name announced in the CXP greeting. The four products
/// of the suite each use their lowercased product short-name; SimCrux's
/// is `simcrux`.
const String simcruxCxpProductName = SimCruxBuildInfo.productName;

/// Default CXP port for SimCrux's server.
///
/// Each Crux product uses a distinct port so all four can run side by
/// side on the same workstation without colliding (per
/// `crux-shared/packages/crux_cxp/README.md`): WaveCrux 54322,
/// NetCrux 54323, LintCrux 54324, SimCrux 54325. Override via the
/// `cxp.port` setting.
const int defaultSimcruxCxpPort = 54325;

/// Product version SimCrux announces in the CXP handshake.
///
/// Aliased to [SimCruxBuildInfo.productVersion] rather than held separately.
/// It used to be its own literal "kept in sync with `pubspec.yaml` by
/// convention", and the convention did not hold: it advertised `0.1.0` to
/// every peer of every 0.8.0 build. One constant, one guard test, no
/// convention to remember.
const String kSimcruxCxpAdvertisedVersion = SimCruxBuildInfo.productVersion;

/// Capabilities the SimCrux peer announces in its handshake.
///
/// v1 CXP does not yet define a `request_open_waveform` message kind;
/// SimCrux models the waveform-open semantics through
/// `ElementKind.source` with a waveform file extension (see
/// `SimCruxNameResolver`). Receivers that recognise the `simcrux.debug`
/// capability know that an `ElementKind.source` whose path looks like a
/// waveform should be opened in a viewer, not an editor.
const Set<String> kSimcruxCxpCapabilities = <String>{
  'simcrux.debug',
};
