// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// The telemetry catalog's conformance guard.
//
// WHY THIS TEST EXISTS, AND WHY IT IS WORTH ITS LENGTH:
//
// The ingestion Worker behind telemetry.edacrux.app validates every
// event it receives, and every one of its rejections is SILENT.
//
//   * An event NAME that fails `^[a-z0-9_]+(\.[a-z0-9_]+){1,2}$` is skipped.
//     The batch still returns 202; the row is counted only in the response's
//     `dropped` field, which the client does not read and no dashboard shows.
//   * A property KEY that fails `^[a-z][a-z0-9_]{0,31}$`, or a VALUE that is
//     neither `[a-z0-9_]{1,64}`, nor a bool, nor an integer with |v| <= 100000,
//     is dropped while the event is KEPT. That is the worse failure: the
//     counter looks healthy and one of its dimensions is permanently empty.
//
// Nothing in the app, the queue, the response, or the SQL API can distinguish
// "nobody used this feature" from "every row was discarded at the edge". So
// the grammar is asserted HERE, client-side, where a violation is a failing
// build instead of a quiet hole in the data.
//
// SimCrux raises the stakes on one rule in particular. The telemetry
// never-collect list rules out test names, suite names, seeds and log content, and this is the product
// where all four are within arm's reach of every call site. The vocabulary
// checks below are the mechanical half of that promise; the "no
// String → String sanitizer" rule is the other half, and it is enforced by
// `telemetryEnumToken` taking an `Enum`.
//
// The rules enforced:
//
//  1. Every event name recorded anywhere in `lib/` appears in the pinned
//     `kSimcruxEventCatalog`. An undocumented event cannot ship.
//  2. Conversely, every catalog entry is still recorded somewhere (Pro-only
//     entries excepted, since they live in the other repo, and the shared
//     `app.uncaught_error`, which `crux_telemetry` records) — a catalog that
//     accumulates dead names stops being a description of the product.
//  3. Every catalog name matches the Worker's event-name class.
//  4. Every property key matches the Worker's property-key class.
//  5. Every enumerated property value matches the Worker's value class.
//  6. The catalog's enum-derived value sets equal what `telemetryEnumToken`
//     produces from the Dart enums they came from, so adding a camelCase
//     constant to `DashboardViewMode` (or a new `DebugInWaveCruxOutcome`)
//     fails here rather than losing a property at the edge.
//  7. No duplicate names; no event over the Worker's six-property cap.
//
// The scanner reads string literals passed to `TelemetryEvent(...)`, which is
// why instrumentation call sites spell their event names as literals rather
// than referencing constants: a constant would make rule 1 vacuous.

import 'dart:io';

import 'package:crux_license/crux_license.dart';
import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/cross_project_search_scope.dart';
import 'package:simcrux/domain/enums/dashboard_view_mode.dart';
import 'package:simcrux/domain/enums/regression_trigger.dart';
import 'package:simcrux/domain/models/flakiness_score.dart';
import 'package:simcrux/domain/models/trend_alert.dart';
import 'package:simcrux/features/remote/services/debug_in_wavecrux_dispatcher.dart';
import 'package:simcrux/services/export/result_exporter.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';
import 'package:simcrux/services/telemetry/gated_feature.dart';
import 'package:simcrux/services/telemetry/telemetry_event_catalog.dart';

/// The ingestion Worker's `EVENT_NAME`.
final _eventName = RegExp(r'^[a-z0-9_]+(\.[a-z0-9_]+){1,2}$');

/// The ingestion Worker's `PROPERTY_KEY`.
final _propertyKey = RegExp(r'^[a-z][a-z0-9_]{0,31}$');

/// The ingestion Worker's `PROPERTY_VALUE`.
final _propertyValue = RegExp(r'^[a-z0-9_]{1,64}$');

/// The Worker's `MAX_PROPERTIES`.
const int _maxProperties = 6;

/// Matches the event-name argument of a `TelemetryEvent('…')` construction, or
/// of the workspace notifier's `_emit('…')` wrapper around one.
///
/// Single-quoted only — the house style throughout `lib/`, and a double-quoted
/// literal would be caught by the analyzer's quote lint first.
final _recordedEvent = RegExp(r"(?:TelemetryEvent|_emit)\(\s*'([^']+)'");

/// Every `TelemetryEvent(` construction, whether or not its first argument is
/// a literal. Used to prove the scanner above sees all of them.
final _anyConstruction = RegExp(r'TelemetryEvent\(');

/// The one place a [TelemetryEvent] is constructed from a variable rather than
/// a literal: the workspace notifier's `_emit` helper, whose callers pass the
/// literal instead and are matched by [_recordedEvent].
///
/// `projectOpenedEvent` is deliberately **not** here — it spells
/// `TelemetryEvent('project.opened'` as a literal and varies only the property
/// value, so the scanner sees it exactly as it sees a direct call site.
const String _indirectConstructionSite =
    'lib/features/workspace/providers/workspace_provider.dart';

/// Catalog entries that live in the Pro overlay and so cannot be found by a
/// scan of this repository. The Pro repo runs the same rule-2 check over its
/// own tree against the same catalog.
const Set<String> _proOnlyEvents = <String>{
  'flaky.panel_opened',
  'flaky.retry_applied',
  'trend.chart_opened',
  'trend.alert_raised',
  'seed_heatmap.opened',
  'comparison.run',
  'baseline.set',
  'pr_annotation.dispatched',
  'plugin.driver_loaded',
  'project.switched',
  'cross_project.searched',
  'riscv.dashboard_opened',
  'riscv.report_exported',
  // The commercial group. Its one recording site is
  // `showProUpgradeDialog`, which lives in the Pro overlay because the dialog
  // does — open core has no `CruxUpgradeDialog` call at all.
  'tier.gate_hit',
};

/// Catalog entries recorded by a shared package rather than by a call site in
/// either repository. `crux_telemetry` records `app.uncaught_error` from the
/// global error handlers, so no scan of this repository's `lib/` can find it,
/// and it is excused from the "still recorded" rule.
const Set<String> _sharedEvents = <String>{'app.uncaught_error'};

void main() {
  const catalog = kSimcruxEventCatalog;

  test('no duplicate catalog entries', () {
    final seen = <String>{};
    final duplicates = <String>[];
    for (final event in catalog) {
      if (!seen.add(event.name)) duplicates.add(event.name);
    }
    expect(duplicates, isEmpty, reason: 'each event is listed once');
  });

  test('every catalog name matches the Worker event-name class', () {
    final bad = [
      for (final event in catalog)
        if (!_eventName.hasMatch(event.name)) event.name,
    ];
    expect(
      bad,
      isEmpty,
      reason:
          'The ingestion Worker drops these names without reporting anything, '
          'so the events would never arrive. Names are lowercase, '
          'dot-separated, two or three segments:\n'
          '${bad.join('\n')}',
    );
  });

  test('every property key matches the Worker property-key class', () {
    final bad = <String>[];
    for (final event in catalog) {
      for (final key in event.propertyKeys) {
        if (!_propertyKey.hasMatch(key)) bad.add('${event.name}.$key');
      }
    }
    expect(
      bad,
      isEmpty,
      reason:
          'A key outside the Worker property-key class is dropped while its '
          'event is kept — the counter survives and the dimension is silently '
          'empty:\n${bad.join('\n')}',
    );
  });

  test('every enumerated property value matches the Worker value class', () {
    final bad = <String>[];
    for (final event in catalog) {
      event.enumeratedValues.forEach((key, values) {
        for (final value in values) {
          if (!_propertyValue.hasMatch(value)) {
            bad.add('${event.name}.$key = $value');
          }
        }
      });
    }
    expect(
      bad,
      isEmpty,
      reason:
          'Values are identifiers from our own vocabulary — no capitals, no '
          'dots, no spaces:\n${bad.join('\n')}',
    );
  });

  test('no event exceeds the Worker property cap', () {
    final over = [
      for (final event in catalog)
        if (event.propertyKeys.length > _maxProperties)
          '${event.name} (${event.propertyKeys.length})',
    ];
    expect(
      over,
      isEmpty,
      reason:
          'The Worker encodes at most $_maxProperties properties per event; '
          'the rest are dropped in key order:\n${over.join('\n')}',
    );
  });

  test('counts are clamped below the Worker integer ceiling', () {
    // The one property class the grammar check above cannot see, because the
    // value is computed rather than listed. A regression with more tests than
    // the ceiling is not hypothetical in a product whose signature feature is
    // parameter sweeps — and an unclamped count would lose the property
    // silently, on exactly the installations whose suite size is the most
    // interesting number in the dataset.
    expect(kTelemetryMaxCount, 100000);
    expect(telemetryCount(0), 0);
    expect(telemetryCount(1), 1);
    expect(telemetryCount(kTelemetryMaxCount), kTelemetryMaxCount);
    expect(telemetryCount(kTelemetryMaxCount + 1), kTelemetryMaxCount);
    expect(telemetryCount(9999999), kTelemetryMaxCount);
    // Saturating, not wrapping and not negative: the Worker rejects |v| > cap
    // in both directions.
    expect(telemetryCount(-1), 0);
  });

  group('enum-derived vocabularies match their Dart enums', () {
    // Each of these pins a catalog value list to the enum it is derived from,
    // so a new constant cannot be added to the enum without the catalog
    // being updated in the same change.

    List<String> valuesFor(String event, String key) =>
        catalog.firstWhere((e) => e.name == event).enumeratedValues[key]!;

    test('debug_in_wavecrux.used.outcome is 1:1 with its enum', () {
      // 1:1, both ways. Three of the eight — dispatched_with_limitation,
      // rejected, unacknowledged — are the ones that describe a hand-off
      // that looked like it worked and did not, so none may go missing.
      expect(
        valuesFor('debug_in_wavecrux.used', 'outcome').toSet(),
        DebugInWaveCruxOutcome.values.map(telemetryEnumToken).toSet(),
      );
      expect(
        kDebugInWaveCruxOutcomeTokens,
        hasLength(DebugInWaveCruxOutcome.values.length),
      );
    });

    test('dashboard.view_changed.mode covers every DashboardViewMode', () {
      expect(
        valuesFor('dashboard.view_changed', 'mode').toSet(),
        DashboardViewMode.values.map(telemetryEnumToken).toSet(),
      );
    });

    test('regression.completed.trigger is RegressionTrigger', () {
      expect(
        valuesFor('regression.completed', 'trigger').toSet(),
        RegressionTrigger.values.map(telemetryEnumToken).toSet(),
      );
    });

    test('export.completed.format covers every ExportFormat, plus the '
        'bundle', () {
      final fromEnum = ExportFormat.values.map((v) => v.id).toSet();
      final fromCatalog = valuesFor('export.completed', 'format').toSet();
      expect(fromCatalog, containsAll(fromEnum));
      // The catalog carries exactly one token the enum does not: the
      // `export-dashboard` sub-command, which writes a directory rather than
      // encoding a document and so has no `ExportFormat` constant.
      expect(fromCatalog.difference(fromEnum), <String>{'web_bundle'});
      // `ExportFormat` ids are already lowercase, so the call site emits `.id`
      // directly. This asserts that remains true.
      expect(
        ExportFormat.values.every((v) => _propertyValue.hasMatch(v.id)),
        isTrue,
        reason:
            'a camelCase ExportFormat id would be dropped by the Worker; '
            'route it through telemetryEnumToken if one is added',
      );
    });

    test('the simulator vocabulary covers every built-in driver id', () {
      // Read from the production provider rather than from a hand-written
      // list, so registering a seventh built-in driver fails here instead of
      // reporting it as `plugin` forever.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final builtIns = container
          .read(simulatorDriverRegistryProvider)
          .simulatorIds
          .toSet();

      expect(
        kSimcruxSimulatorTokens.toSet(),
        containsAll(builtIns),
        reason:
            'a built-in simulator id missing from the catalog would report as '
            '`plugin`, merging a first-party engine into the third-party '
            'bucket: $builtIns',
      );
      // `demo` is gated off by default (SIMCRUX_DEMO_RUNNER), so it is not in
      // `builtIns` here — but it can appear in a run, and its absence from the
      // catalog would drop the property on every demo walkthrough.
      expect(kSimcruxSimulatorTokens, contains('demo'));
      // `plugin` is the fold-to token, and `mixed` only ever describes a whole
      // regression, never one engine.
      expect(kSimcruxSimulatorTokens, contains('plugin'));
      expect(kSimcruxSimulatorTokens, isNot(contains('mixed')));
      expect(kSimcruxRegressionSimulatorTokens, contains('mixed'));
      expect(
        valuesFor('engine.missing', 'simulator'),
        kSimcruxSimulatorTokens,
        reason: 'a missing engine is one engine — `mixed` is meaningless here',
      );
    });

    test('tier.gate_hit.feature is 1:1 with SimcruxGatedFeature', () {
      // Both directions. A gate site added without a constant here would send
      // a value outside the declared set — the Worker drops it, the event
      // survives, and `tier.gate_hit` reports an upgrade signal that cannot
      // say which feature produced it. A constant added without a gate site
      // is the mirror failure: a real zero on a dashboard.
      expect(
        valuesFor('tier.gate_hit', 'feature').toSet(),
        SimcruxGatedFeature.values.map(telemetryEnumToken).toSet(),
      );
      expect(
        kSimcruxGatedFeatureTokens,
        hasLength(SimcruxGatedFeature.values.length),
      );
    });

    test('tier.gate_hit.required is pro or enterprise, and nothing else', () {
      // A gate never demands `edu`, because
      // `featureEquivalent` maps `edu → pro` and an EDU seat satisfies every
      // Pro gate; and a feature that demanded `openCore` would not be a gate.
      // Asserted against the real `LicenseTier` so a renamed constant fails
      // here rather than at the edge.
      expect(kSimcruxRequiredTierTokens, <String>[
        LicenseTier.pro.name,
        LicenseTier.enterprise.name,
      ]);
      expect(kSimcruxRequiredTierTokens, isNot(contains(LicenseTier.edu.name)));
      expect(
        kSimcruxRequiredTierTokens,
        isNot(contains(LicenseTier.openCore.name)),
      );
      // `LicenseTier` names are already lowercase single words, so the call
      // site sends `.name` directly rather than routing through
      // `telemetryEnumToken`. `openCore` is the one camelCase constant and it
      // is excluded above, but assert the property anyway — a future
      // camelCase tier that a gate *could* demand would be dropped silently.
      for (final token in kSimcruxRequiredTierTokens) {
        expect(_propertyValue.hasMatch(token), isTrue, reason: token);
      }
    });

    test('trend.alert_raised.kind is 1:1 with TrendAlertKind', () {
      expect(
        valuesFor('trend.alert_raised', 'kind').toSet(),
        TrendAlertKind.values.map(telemetryEnumToken).toSet(),
      );
    });

    test('cross_project.searched.scope covers every search scope', () {
      expect(
        valuesFor('cross_project.searched', 'scope').toSet(),
        CrossProjectSearchScope.values.map(telemetryEnumToken).toSet(),
      );
    });

    test('flaky.retry_applied.classification is the retry-eligible band', () {
      // A strict subset of `FlakyClassification`, and the exclusions are the
      // assertion: `FlakyRetryPolicy` refuses to retry a `stable` or a
      // `consistentlyFailing` test, so neither can ever be recorded here.
      final fromCatalog = valuesFor(
        'flaky.retry_applied',
        'classification',
      ).toSet();
      final fromEnum = FlakyClassification.values.map(telemetryEnumToken);
      expect(fromEnum.toSet(), containsAll(fromCatalog));
      expect(
        fromEnum.toSet().difference(fromCatalog),
        <String>{
          telemetryEnumToken(FlakyClassification.stable),
          telemetryEnumToken(FlakyClassification.consistentlyFailing),
        },
      );
    });

    test("detector kinds are the project file's own pass_fail types", () {
      // The user writes these words in `simcrux.yaml`; the loader's switch is
      // the vocabulary, and the token they see in the data must be the same
      // word. Read out of the loader's error message so the two cannot drift.
      final loaderSource = File(
        'lib/services/config/config_loader_pass_fail.dart',
      ).readAsStringSync();
      for (final kind in kSimcruxDetectorKindTokens) {
        expect(
          loaderSource,
          contains("'$kind'"),
          reason:
              '`$kind` is not a `pass_fail: type:` the config loader accepts, '
              'so no run can ever produce it',
        );
      }
    });
  });

  test('app.uncaught_error carries the shared counter vocabulary', () {
    // Recorded by `crux_telemetry`, not by this repository, so the lists are
    // the package's: four properties, no free text, a catch-all in each
    // open-ended dimension, and `none` for an error with no framework library.
    final entry = catalog.firstWhere((e) => e.name == 'app.uncaught_error');
    expect(entry.propertyKeys.toSet(), <String>{
      'source',
      'kind',
      'library',
      'silent',
    });
    expect(entry.boolProperties, <String>['silent']);
    expect(entry.intProperties, isEmpty);
    // Exactly the package's lists: a value the counter records and the
    // catalog lacks, or the reverse, is a row the Worker and this catalog
    // disagree about. The catalog holds a literal copy (it is in the
    // headless CLI's import closure, and crux_telemetry imports Flutter), so
    // this equality is the only thing that keeps the copy honest.
    expect(entry.enumeratedValues['source'], kTelemetryUncaughtErrorSources);
    expect(entry.enumeratedValues['kind'], kTelemetryUncaughtErrorKinds);
    expect(entry.enumeratedValues['library'], kTelemetryUncaughtErrorLibraries);
    expect(entry.enumeratedValues['kind'], contains('other'));
    expect(
      entry.enumeratedValues['library'],
      containsAll(<String>['none', 'other']),
    );
  });

  group('source scan', () {
    final recorded = <String, Set<String>>{};
    // Files holding a `TelemetryEvent(` the name scanner could not read a
    // literal out of. Exactly one is expected, and it is the `_emit` wrapper.
    final opaqueConstructions = <String>[];

    final libDir = Directory('lib');
    if (!libDir.existsSync()) {
      throw StateError('run from the package root (flutter test)');
    }
    for (final entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      if (path.endsWith('.g.dart')) continue;
      final source = entity.readAsStringSync();
      var literalConstructions = 0;
      for (final match in _recordedEvent.allMatches(source)) {
        recorded.putIfAbsent(match.group(1)!, () => <String>{}).add(path);
        if (match.group(0)!.startsWith('TelemetryEvent')) {
          literalConstructions++;
        }
      }
      final total = _anyConstruction.allMatches(source).length;
      for (var i = literalConstructions; i < total; i++) {
        opaqueConstructions.add(path);
      }
    }

    test('the scan found the instrumentation at all', () {
      // A regex that silently stops matching would turn the rules below into
      // tests that assert nothing, so assert the scanner is alive.
      expect(
        recorded.length,
        greaterThan(10),
        reason:
            'the TelemetryEvent scan matched almost nothing — the call-site '
            'idiom probably changed and this guard has gone blind',
      );
    });

    test('no event name is hidden from the scanner behind an indirection', () {
      // The closure property that makes "every recorded name is in the
      // catalog" mean something: an event constructed from a variable is an
      // event this file cannot see, and so an event that could ship
      // undocumented. One such indirection exists by design.
      expect(
        opaqueConstructions,
        <String>[_indirectConstructionSite],
        reason:
            'A TelemetryEvent built from a non-literal name is invisible to '
            'the catalog check. Spell the name as a literal at the call site, '
            'or — if a new thin wrapper is genuinely warranted — teach '
            '_recordedEvent to read its callers and list it here.',
      );
    });

    test('every recorded event name is in the catalog', () {
      final names = kSimcruxEventNames;
      final undocumented = [
        for (final entry in recorded.entries)
          if (!names.contains(entry.key))
            '${entry.key}  (${entry.value.join(', ')})',
      ];
      expect(
        undocumented,
        isEmpty,
        reason:
            'An event that is not in kSimcruxEventCatalog is an event nobody '
            'vetted against the never-collect list and nobody wrote down. Add '
            'it to the catalog or remove the call site:\n'
            '${undocumented.join('\n')}',
      );
    });

    test('every open-core catalog entry is still recorded', () {
      final dead = [
        for (final event in catalog)
          if (!_proOnlyEvents.contains(event.name) &&
              !_sharedEvents.contains(event.name) &&
              !recorded.containsKey(event.name))
            event.name,
      ];
      expect(
        dead,
        isEmpty,
        reason:
            'These catalog entries have no call site in this repository. If '
            'the feature was removed, remove the entry; if the event moved to '
            'the Pro overlay, add it to _proOnlyEvents:\n${dead.join('\n')}',
      );
    });

    test('the two workspace events SimCrux cannot reach are absent', () {
      // The suite's shared workspace set lists eight names. SimCrux has no
      // "New Workspace" and no "Save Workspace As" action, so two of them have
      // no reachable call site here. They are absent from the catalog rather
      // than present-and-never-recorded, because on a dashboard a counter
      // wired to an unreachable path is indistinguishable from a feature
      // nobody uses — which is the exact question these counters answer.
      expect(kSimcruxEventNames, isNot(contains('workspace.created')));
      expect(kSimcruxEventNames, isNot(contains('workspace.named.saved')));
      expect(recorded.keys, isNot(contains('workspace.created')));
      expect(recorded.keys, isNot(contains('workspace.named.saved')));
    });
  });
}
