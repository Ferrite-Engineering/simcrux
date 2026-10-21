// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_sqlite/crux_sqlite.dart';

/// Version-numbered, append-only up-migrations for the SQLite trend store.
///
/// This is a plain list and nothing else. The runner that owns it, derives
/// the latest version from its length, and rejects a downgrade is
/// `CruxMigrationRunner` in `package:crux_sqlite` — see `sql_trend_store_io.dart`
/// for where it is built and opened through.
///
/// To add a new migration: append a new [CruxMigration] without modifying
/// any earlier entry, then add a test that loads an old DB at the previous
/// version and verifies the migration produces the expected schema. There is
/// no version constant to bump — [CruxMigrationRunner.latestVersion] is
/// derived from this list's length.
/// **`runs.passed` / `failed` / `errored` / `timed_out` / `skipped` are
/// reserved and never populated.** Nothing writes them, so every row carries
/// their `DEFAULT 0` — which a SQL browser or a support export reads as "no
/// tests passed" rather than as "not recorded".
///
/// They are not populated because they cannot be, honestly: they encode a
/// CI-runner vocabulary SimCrux does not record. There is no `errored`
/// status at all, and `vacuous`, `cover`, `cancelled` and `unknown` map to no
/// column — so filling in the four that do map would produce counts that
/// silently fail to sum to `total_tests`, which is a worse lie than the
/// zeros. `test_results.status` carries the real per-test outcome and is what
/// every query in this file reads.
///
/// Dropping them is the actual fix and is deferred past 1.0 on purpose: G1
/// forbids editing a shipped migration, so it needs a new additive version
/// and a data-preserving test, which is not work to do during a freeze.
final List<CruxMigration> simcruxTrendStoreMigrations = <CruxMigration>[
  CruxMigration(
    version: 1,
    description: 'Create runs + test_results tables and their indexes',
    apply: (db) async {
      await db.execute('''
CREATE TABLE runs (
  id              TEXT PRIMARY KEY,
  started_at      INTEGER NOT NULL,
  finished_at     INTEGER,
  config_hash     TEXT NOT NULL,
  git_commit      TEXT,
  git_branch      TEXT,
  trigger_kind    TEXT NOT NULL,
  total_tests     INTEGER NOT NULL,
  passed          INTEGER NOT NULL DEFAULT 0,
  failed          INTEGER NOT NULL DEFAULT 0,
  errored         INTEGER NOT NULL DEFAULT 0,
  timed_out       INTEGER NOT NULL DEFAULT 0,
  skipped         INTEGER NOT NULL DEFAULT 0,
  metadata        TEXT NOT NULL
);
''');
      await db.execute('''
CREATE TABLE test_results (
  id              TEXT PRIMARY KEY,
  run_id          TEXT NOT NULL REFERENCES runs(id),
  test_name       TEXT NOT NULL,
  suite_name      TEXT NOT NULL,
  simulator       TEXT NOT NULL,
  parameters      TEXT NOT NULL,
  status          TEXT NOT NULL,
  runtime_ms      INTEGER NOT NULL,
  started_at      INTEGER NOT NULL,
  log_path        TEXT,
  waveform_path   TEXT,
  failure_reason  TEXT,
  metadata        TEXT NOT NULL
);
''');
      await db.execute(
        'CREATE INDEX idx_results_run ON test_results(run_id);',
      );
      await db.execute(
        'CREATE INDEX idx_results_test_name ON test_results(test_name);',
      );
      await db.execute(
        'CREATE INDEX idx_results_status ON test_results(status);',
      );
      await db.execute(
        'CREATE INDEX idx_results_simulator ON test_results(simulator);',
      );
    },
  ),
  CruxMigration(
    version: 2,
    description:
        'Composite (test_name, started_at) index for the flaky-detection '
        'aggregate — without it the per-test, time-ordered scan over '
        'last-N runs degrades to a table scan + sort at 10k+ rows.',
    apply: (db) async {
      await db.execute(
        'CREATE INDEX idx_results_test_started '
        'ON test_results(test_name, started_at);',
      );
    },
  ),
  CruxMigration(
    version: 3,
    description:
        'Index runs(started_at). Every recent-runs window — recentDeltas, '
        'distinctTestIds, recentTrendsFor — opens with '
        '`SELECT id FROM runs ORDER BY started_at DESC LIMIT n`, which '
        'without this index is a full scan of a table that (until the '
        'same change taught applyRetention to prune it) only ever grew.',
    apply: (db) async {
      await db.execute('CREATE INDEX idx_runs_started ON runs(started_at);');
    },
  ),
  // The shared `schema_meta` shape — defined and written by `crux_sqlite`,
  // identical in all four Crux SQLite databases, deliberately not a SimCrux
  // design (`crux-shared/packages/crux_sqlite/README.md`).
  //
  // Pure DDL here; the rows are written by `CruxMigrationRunner` inside this
  // same transaction, which is what makes the ledger evidence rather than a
  // claim. An existing `trends.db` gains both tables on this upgrade with its
  // v1–v3 history backfilled as "ran, at an unrecorded time, by an unrecorded
  // build" — the truth — rather than with a fabricated timestamp.
  cruxSchemaMetaMigration(version: 4),
  // Formal and implementation-flow history, added in one step so the two
  // capabilities never race for the next version number. Every table is
  // keyed by the existing `runs.id` and `test_results.test_name`, so the
  // retention pass that prunes a run must prune these rows with it. Foreign
  // keys are not declared: SQLite does not enforce them here, and the team
  // database's PostgreSQL copy of these tables does.
  //
  // - `flow_steps` / `flow_metrics`: one implementation-flow run's steps and
  //   its metrics. `key` is the full METRICS2.1 key, `base` the key without
  //   its modifiers, `modifiers` a JSON object in insertion order.
  // - `formal_runs`: one row per formal task result, the `formal.*` metrics
  //   a trend query filters on, as columns.
  // - `formal_properties`: the cross-run identity of a property within a
  //   test. `property_key` is its label when the frontend kept one, else the
  //   `crux-fnv1a64/1` signature over task, kind, file and normalised source
  //   text, line numbers excluded; `key_scheme` says which.
  // - `formal_property_results`: one property's status in one run.
  //   `location` is the project-relative `file:line[:col]` the status stream
  //   reported, which identifies the property within that run only. `steps`
  //   is the trace length for a counterexample or a reached cover, and the
  //   bound for a property that held over it.
  // - `flow_gls_results`: one gate-level simulation of one test against one
  //   flow run's netlist. The per-sample differences are never stored; they
  //   are recomputed from the two dumps when the triage view opens.
  CruxMigration(
    version: 5,
    description:
        'Formal and implementation-flow history: flow_steps, flow_metrics, '
        'formal_runs, formal_properties, formal_property_results and '
        'flow_gls_results, with their indexes',
    apply: (db) async {
      await db.execute('''
CREATE TABLE flow_steps (
  run_id TEXT NOT NULL, test_id TEXT NOT NULL,
  ordinal INTEGER NOT NULL, step_id TEXT NOT NULL, tool TEXT,
  status TEXT NOT NULL, runtime_ms INTEGER
);
''');
      await db.execute('''
CREATE TABLE flow_metrics (
  run_id TEXT NOT NULL, test_id TEXT NOT NULL,
  key TEXT NOT NULL,
  base TEXT NOT NULL,
  modifiers TEXT NOT NULL,
  value_real REAL, value_text TEXT,
  aggregated INTEGER NOT NULL DEFAULT 0
);
''');
      await db.execute(
        'CREATE INDEX idx_flow_metrics_base ON flow_metrics(test_id, base);',
      );
      await db.execute('''
CREATE TABLE formal_runs (
  run_id                TEXT NOT NULL,
  test_id               TEXT NOT NULL,
  tool                  TEXT NOT NULL,
  task                  TEXT,
  mode                  TEXT,
  verdict               TEXT NOT NULL,
  depth_configured      INTEGER,
  depth_reached         INTEGER,
  wall_time_ms          INTEGER,
  wall_time_source      TEXT,
  engine                TEXT,
  solver                TEXT,
  frontend              TEXT,
  properties            INTEGER,
  properties_failed     INTEGER,
  properties_undecided  INTEGER,
  verdict_disagreement  INTEGER NOT NULL DEFAULT 0
);
''');
      await db.execute(
        'CREATE INDEX idx_formal_runs_test ON formal_runs(test_id);',
      );
      await db.execute('''
CREATE TABLE formal_properties (
  test_id            TEXT NOT NULL,
  property_key       TEXT NOT NULL,
  key_scheme         TEXT NOT NULL,
  task               TEXT,
  kind               TEXT NOT NULL,
  label              TEXT,
  first_seen_run_id  TEXT NOT NULL,
  PRIMARY KEY (test_id, property_key)
);
''');
      await db.execute('''
CREATE TABLE formal_property_results (
  run_id            TEXT NOT NULL,
  test_id           TEXT NOT NULL,
  property_key      TEXT NOT NULL,
  location          TEXT NOT NULL,
  status            TEXT NOT NULL,
  steps             INTEGER,
  trace_path        TEXT,
  pretrace_exposed  INTEGER NOT NULL DEFAULT 0
);
''');
      await db.execute(
        'CREATE INDEX idx_formal_property_results_key '
        'ON formal_property_results(test_id, property_key);',
      );
      await db.execute('''
CREATE TABLE flow_gls_results (
  run_id         TEXT NOT NULL,
  test_id        TEXT NOT NULL,
  flow_run_id    TEXT NOT NULL,
  netlist        TEXT NOT NULL,
  delays         TEXT NOT NULL,
  outcome        TEXT NOT NULL,
  real_diffs     INTEGER,
  x_diffs        INTEGER,
  first_diff_ps  INTEGER
);
''');
      await db.execute(
        'CREATE INDEX idx_flow_gls_test ON flow_gls_results(test_id);',
      );
    },
  ),
];
