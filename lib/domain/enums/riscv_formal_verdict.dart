// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/domain/enums/formal_verdict.dart';

/// The RISC-V formal track's name for [FormalVerdict], kept for one minor
/// release so existing callers keep compiling. Same values, same wire
/// names, same `TestStatus` mapping: it is the same type.
///
/// New code uses [FormalVerdict]. This alias is marked deprecated only
/// once no caller in SimCrux or its Pro overlay still uses it, because
/// the analyzer reports every use of a deprecated name and the build
/// treats infos as fatal.
typedef RiscvFormalVerdict = FormalVerdict;
