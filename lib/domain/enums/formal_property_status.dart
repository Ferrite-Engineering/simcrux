// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/domain/enums/formal_bucket.dart';
import 'package:simcrux/domain/enums/formal_verdict.dart';

/// What one property of one formal task ended as, after the status stream
/// and `status.sqlite` were reconciled.
///
/// Two values exist only per property: [reached] and [notReached], for
/// cover statements. Everything else maps onto a [FormalVerdict] token.
enum FormalPropertyStatus {
  /// An assertion held.
  proved('proved', FormalVerdict.pass),

  /// A cover statement was reached; the trace is its witness.
  reached('reached', FormalVerdict.pass),

  /// An assertion failed and the engine produced a base-case trace.
  counterexample('counterexample', FormalVerdict.fail),

  /// A cover statement was shown unreachable within the bound. No trace.
  notReached('not_reached', FormalVerdict.fail),

  /// Undecided: only progress records, an induction failure (which is not
  /// a trace of the design), or no record under a task that did not pass.
  inconclusive('inconclusive', FormalVerdict.unknown),

  /// No status record at all under a task that reported `PASS`. Never read
  /// as proved.
  didNotRun('did_not_run', FormalVerdict.noOutcome);

  const FormalPropertyStatus(this.wireName, this.verdict);

  /// Stable token, the value of `formal.property.<n>.status`. Never
  /// localize it.
  final String wireName;

  /// The task-level verdict token this status corresponds to.
  final FormalVerdict verdict;

  /// The display bucket.
  FormalBucket get bucket => FormalBucket.of(verdict);

  /// How strongly this status contradicts a proof, for the agreement
  /// rule: the higher rank is the more conservative fact. A proof is the
  /// least conservative claim and ranks lowest.
  int get conservativeRank => switch (this) {
    FormalPropertyStatus.proved || FormalPropertyStatus.reached => 0,
    FormalPropertyStatus.inconclusive => 1,
    FormalPropertyStatus.didNotRun => 2,
    FormalPropertyStatus.counterexample || FormalPropertyStatus.notReached => 3,
  };

  /// Parses a stored token, or null.
  static FormalPropertyStatus? fromWireName(Object? raw) {
    for (final status in FormalPropertyStatus.values) {
      if (status.wireName == raw) return status;
    }
    return null;
  }
}
