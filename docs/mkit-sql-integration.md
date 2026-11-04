# mkit-sql in MK Studio: how it is wired, what was found, what is still different

State described here: MK Studio with **mkit-sql 0.4.1** (`atyr647/mkit-sql` at `c6e2c78`) vendored in
`mkstudio.vfs/lib/mkitsql`. Everything below was run, not read off a description.

## 1. How it is wired

- **The engine is part of the starpack.** `mkstudio.vfs/lib/mkitsql/*.tcl` are copies of the files in mkit-sql's `mkitsql/`;
  `mkstudio.vfs/lib/mkitsql/SOURCE` names version and commit. `tools/sync-mkitsql.sh <mkit-sql checkout>` updates the copy (and
  refuses an uncommitted checkout: the copy must always name a real commit); `tools/sync-mkitsql.sh --check <checkout at that
  commit>` fails on any difference, and CI runs it on every push. Nothing is fetched at build time.
- **The loader chooses the engine** (`loader.tcl`): mkit-sql plus its `engine_studio.tcl` by default - which redefines
  `::engine::parseScript` / `::engine::execute` and shares `::engine::cancel`, `maxRows` and `progressHook` with the engine's
  loops, so the Stop button works inside it. `MKS_ENGINE=mkql` starts the program with the small built-in dialect instead (the
  tests use it as a stand-in and reference, e.g. the grid's streaming-result tests).
- **Storage is MK Studio's `store.tcl`.** mkit-sql notices `::store` and uses its `db_studio.tcl` adapter: one set of open
  files, one lock, one commit protocol. A statement's change is a change in the open database; the toolbar's Commit / Roll Back
  and SQL's `COMMIT` / `ROLLBACK` are the same mechanism.
- **UI changes that came with it** (mkit-sql's `integration/mkstudio.patch`): script files default to `.sql`, the explorer
  refreshes after `MERGE`, the sample script uses `LIMIT`, `store::dropView` empties a view before dropping it (Metakit's
  `mk::view delete` leaves the rows behind: a table re-created under the same name came back with its old rows), the repairs in
  `store::repairFile` only cut or restore a file when a valid Metakit footer ends where they are about to cut (a damaged
  record must never make them throw real data away), and row reads go through a workaround for a list bug in Tcl 8.5 and
  8.6.3 (rows whose first cell is text starting with `#`; healthy Tcl versions - including the 8.6.18 runtime the programs are
  built on - skip it).

## 2. Conflicts, and how they were resolved

- **The integration patch no longer applied.** It was written against an older `store.tcl`; since then `endCommit` has been
  rewritten (the commit record is made harmless before it is deleted, a failed delete is reported). `git apply` failed on that
  context; `git apply --3way` merged all four files cleanly and the result was checked by running the suites below. The patch
  itself is now history: the changes are in MK Studio's own sources, and mkit-sql's `integration/install-into-mkstudio.sh` has
  nothing left to do (see 4).
- **Two commit-record rules, compatible.** After a finished commit MK Studio rewrites the record to describe the finished file,
  then deletes it; mkit-sql empties a record it cannot delete. Either leaves a record that the other's `repairFile` ignores
  (an empty or matching record is deleted, never acted on). The record formats are unchanged: `<header-hex16> <size>` or `empty 0`.
- **`.sum`.** Same format (`<crc32> <size> <mtime>`); mkit-sql additionally re-stamps a sum whose size and time are the same
  second as the last commit and refuses to open a file whose sum says "damaged" (MK Studio's UI instead offers *Restore Backup*
  / *Open Anyway* at open time, before any statement runs; mkit-sql only meets the question when *it* opens a file).
- **Locks.** Identical line format, guard name and limits (`docs/CONCURRENCY.md`, "Conformance"). Both resolve symbolic links,
  both refuse to follow a lock that is not a plain file. Differences: see 3.
- **The engine and the optimisations.** The built-in dialect's streaming `provider` results exist only there; mkit-sql returns
  its rows. The grid handles both, which is why `tests/test_grid.tcl` pins `MKS_ENGINE=mkql` (it is testing the provider path)
  while `tests/gui_logic.tcl` and `tests/test_engine_wiring.tcl` run on mkit-sql.

## 3. What was run against what

Against **this** `store.tcl` (current runtime 8.6.18, the 2014 8.6.3 and 8.5.17 kits, Linux; Windows and macOS run the engine
wiring and UI suites):

| suite (mkit-sql's own, run with `MKIT_STORE` = this store.tcl) | result |
|---|---|
| `studio_contract` (38), `studio_integration` (16), `studio_listbug` (5), `studio_repair` (8) | pass |
| `run` (586 engine tests), `review_regress` (141), `dropview` (34), `insertrows` (24) | pass |
| `first_commit` (31), `commitfail` / `commitfail_records`, `damage` (70) | pass |
| `attest` (13: `-verify` as a proof from MK Studio's `.sum`), `locking` (75), `lock_crash` (34) | pass |
| `power_loss` (515 synthesised after-power-cut states) | pass |
| `lock_takeover` (29: the takeover step by step, starved processes, two reapers of one guard), `lock_crash` (40) | pass |

and MK Studio's `tests/test_engine_wiring.tcl` (29: engine identity and version, parse offsets and syntax-error codes for the
editor, a statement's change in the store's open database, commit, checksum, lock, rollback, foreign-lock refusal),
`tests/gui_logic.tcl` (64, on mkit-sql), `tests/test_lock_protocol.tcl` (mixed races with mkit-sql's implementation).
CI repeats the studio-side suites on every push - on the pinned commit (must pass) and on mkit-sql's newest commit (may fail:
early warning of drift).

## 4. What was different, what was done in mkit-sql, what still is

Everything that used to be a patch is now in mkit-sql itself (0.4.1, pushed to `atyr647/mkit-sql`, branch `ccr-f017368d-kguqg8`; it
descends from the default branch, so it merges without a conflict) and vendored here:

1. **A lock file that exists but cannot be read counted as free** (`lockInfo`: the `open` failure was read as "vanished meanwhile").
   Another user's lock under a strict umask was then taken over. Now held, as in MK Studio.
2. **mkit-sql's Windows flush was a no-op when the host is a GUI program** (`syncWindows` started PowerShell directly; a Windows GUI
   program has no console, Tcl then starts console programs without one, and PowerShell does nothing at all - exit status 0, no
   output, no effect: measured on real `windows-latest` runners with the 2014 and the current tclkit). MK Studio had exactly this bug in
   1.0.0-rc.1; mkit-sql copied it, and `tests/syncdisk.tcl` only checked the return value. Now PowerShell is started through `cmd /c`
   with `-EncodedCommand` (which also carries accented file names intact), and the test requires that a script really wrote a file.
3. **The takeover deleted the stale lock by name** - which lets a second process destroy a live owner's brand-new lock when the
   takeover guard is wrongly removed (see `docs/CONCURRENCY.md`; reproduced on demand). Both implementations now move the lock aside
   with one atomic rename, judge the *moved* file and put a live lock back; and a process that wrote its pid into a lock file that had
   been overtaken meanwhile notices. `tests/lock_takeover.tcl` (mkit-sql) and `tests/test_lock_crash.tcl` (here) test the same scenarios.
4. `integration/install-into-mkstudio.sh` failed against an MK Studio that carries the integration (the patch was already applied);
   it now says so and exits 0. mkit-sql has a `LICENSE` file (MIT).
5. mkit-sql's CI job `mkstudio` checks out MK Studio's *default* branch - at the time of writing the branch this work is on
   (`ccr-f017368d-kguqg8`; nothing was merged or opened as a pull request from here), so it tests the integrated MK Studio.
6. **mkit-sql's `damage` suite can kill the process it runs in.** It feeds randomly damaged files to Metakit inside the test
   process; on the current 8.6.16 runtime the process died with a segmentation fault in one CI run out of four (the same suite
   passed on the others and locally). It tests mkit-sql's own storage layer, which MK Studio does not use, so CI retries it and
   warns instead of failing on a death by signal; any ordinary failure still fails. mkit-sql's `-verify` (a throw-away child
   process) is the intended defence against exactly this, and the suite would be safer if it ran each file in one too.
7. Still different, not needed for correctness: mkit-sql's pid-reuse check is Linux-only (MK Studio: also macOS and Windows) - the
   stricter-only direction, so a dead process's lock can stay until removed by hand (MK Studio's dialog has *Remove Lock...*);
   the commit-time check (`verifyLock`) exists only here.
8. mkit-sql's results are capped at 100,000 rows and some statements are slower than MK Studio's built-in dialect (README of
   mkit-sql has the table); `MKS_ENGINE=mkql` is the workaround.

## 5. The earlier bulk-mutation comparison

An earlier version of this file compared `DELETE` / `UPDATE` of 200,000-row tables between MK Studio's own engine and
mkit-sql at `fa3f77d` (MK Studio's rebuild was as fast or faster; mkit-sql's `bulkMin = 20000` left a wide range on the
quadratic path). mkit-sql has changed since (a rebuild strategy for big deletes/updates, the `-glob` pushdown, a faster
tokenizer); the numbers were not repeated and are dropped. `tests/bench_mutation.tcl` still runs both on identical files in CI
and compares the resulting tables row by row.

## 6. Updating the vendored copy

    git -C ../mkit-sql log -1                       # the commit you mean to take
    tools/sync-mkitsql.sh ../mkit-sql                # copies, writes SOURCE
    # run: tests/test_engine_wiring.tcl, tests/gui_logic.tcl, and CI's `interop` job (pinned) on the pushed commit

An engine that is not mkit-sql can use the same seam: `docs` in `engine.tcl` is the contract, `tests/engine_contract.tcl` the
check, and `tests/provider_contract.tcl` the conformance suite for streaming results.
