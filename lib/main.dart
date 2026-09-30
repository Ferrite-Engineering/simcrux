// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/app.dart';

/// Open-core `simcrux` entry point. The Pro/Enterprise overlay
/// re-enters through the same [runSimcrux] / `bootstrap`
/// exported from `package:simcrux/app.dart`, layering `proOverrides` on top of
/// the open-core `ProviderScope`. See `docs/ARCHITECTURE.md` (Extension
/// Points) and the WaveCrux reference implementation, `lib/app.dart` in the
/// `wavecrux` repository, for the canonical pattern.
Future<void> main(List<String> args) => runSimcrux(args: args);
