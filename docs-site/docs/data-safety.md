# Local database safety

SimCrux keeps its regression history in local SQLite files. Every one of them is opened
through one shared code path, `crux_sqlite`, which the whole EDACrux suite
uses, so the guarantees below are the same in every product and are
enforced in code and in CI rather than by convention. This page states what
they are, so that a reviewer can test them.

## The files {#files}

| File | Holds | If the file is unreadable |
|---|---|---|
| `trends.db` | Run and test history behind the dashboard, trends and flaky detection | Moved aside, a fresh file opens |

"Moved aside" means the damaged file is renamed to
`<file>.corrupt-<UTC timestamp>` (with any `-journal` beside it), a fresh
database opens in its place, and SimCrux reports that it did so; it is
never a silent reset. "Refused"
means SimCrux reports that the file could not be opened and changes
nothing. **No file that holds your history is ever deleted**, on corruption,
on a version mismatch, or for any other reason. The only database the suite
ever deletes is a cache whose contents the next run regenerates.

## What is guaranteed {#guarantees}

- **A busy database is never mistaken for a broken one.** Every open waits up
  to 5 seconds for a lock held by another process (a second window, a CI job
  writing the same file) instead of failing at once.
- **Upgrades are additive.** A newer version adds tables and columns; it does
  not drop or rename the ones your data is in. CI fails the build if a
  migration drops, renames or deletes without an explicit, reviewed
  exception marked beside the statement, or if a migration that has already shipped is edited.
- **An upgrade either completes or changes nothing.** Each schema upgrade
  runs in one exclusive transaction. If it fails, the file stays at its old
  version with all of its data, and SimCrux reports the failure instead of
  starting over with an empty file.
- **An older build never damages a newer file.** Opening a file written by a
  newer version of SimCrux is refused with both version numbers, the app
  version that last wrote the file, and the path of the pre-upgrade backup
  (below), which the older build can open.
- **Every upgrade path is tested with real data.** For each schema version
  there is a fixture database populated the way that version wrote it; CI
  upgrades it to the current schema and checks that every row and value
  survived.

## The pre-upgrade backup {#backup}

Before SimCrux upgrades the schema of a file that holds your history, it
writes a complete copy next to it:

```
trends.db.pre-v<old version>-<UTC timestamp>.bak
```

for example `trends.db.pre-v2-20260820T090000Z.bak`. The timestamp uses the
basic ISO 8601 form, without colons, so the name is valid on Windows.

- **It is a database copy, not a file copy.** The backup is written with
  SQLite's `VACUUM INTO`, which produces a consistent database even while the
  file is open. Copying the bytes of an open SQLite file can capture a state
  the database never committed.
- **No backup, no upgrade.** If the backup cannot be written, the upgrade
  does not run and the file is left exactly as it was. The error says why and
  what to do.
- **Free disk space is checked for large files.** For a database larger than
  256 MiB, SimCrux first checks the free space on that volume and refuses
  the backup (and so the upgrade) when less than 1.1 times the database's
  size is free. If the free space cannot be measured, the backup is attempted
  and is itself the check: a backup that runs out of room fails, and the
  upgrade does not run. Files that stay within the retention settings are far
  below this size, so the check normally never runs.
- **Two backups are kept.** Older backups are removed only after an upgrade
  has succeeded, so a failed upgrade keeps every backup there is.

## Going back to an older version {#downgrade}

If you install an older SimCrux after a newer one has upgraded a file, the
older build refuses to open that file and names the most recent
`.pre-v<n>` backup. To keep using the older build, close SimCrux, rename the
current file aside, and copy the backup to the original name. The newer
version's file is untouched, so you can switch back later.

## Where the files are {#where}

`trends.db` lives in SimCrux's application-support folder, or in `.simcrux/trends.db` inside the project directory when the project keeps its own history (see [Trends & flaky tests](trends-and-flaky.md)).

Back them up with the rest of your user data. A `.corrupt-` or `.bak` file
beside one of them is safe to keep or delete once you no longer need it;
SimCrux never reads them again.
