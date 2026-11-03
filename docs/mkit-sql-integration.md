# mkit-sql and MK Studio: what was checked, what was found

Checked against `atyr647/mkit-sql` at `fa3f77d` (benchmark) and `210c3b7` (protocol, contract, integration) and this repository. Everything below was measured or run, not read off
a description. The mkit-sql checkout was only read; nothing was changed or pushed there.

## 1. Do the two still fit? Yes

mkit-sql's own `tests/studio_contract.tcl` (38 checks) and `tests/studio_integration.tcl` (16 checks) pass against this
checkout (Tcl 8.6.3, real Metakit), and so does `tests/locking.tcl` with `MKSTUDIO_DIR` set (75 checks at `210c3b7`). The CI job
`interop` in `.github/workflows/build.yml` re-runs them on every push (non-blocking, because the other repository can
change on its own).

## 2. Lock protocol: one real defect in both implementations (still in mkit-sql), and a correction of mine

**A correction first.** `docs/CONCURRENCY.md` at `3853497` defined the protocol as `pid host [role [endpoint]]`, mutex
`<db>.lock.guard`, abandonment 5 s / 10 s. mkit-sql (now `210c3b7`) implemented exactly that "to the letter". In
`670fc86` I then changed MK Studio on my own to `pid host start [role [endpoint]]`, `.lock.takeover` and 10 s / 30 s,
because I had compared against an older mkit-sql checkout. That would have broken the agreement: a lock mkit-sql wrote
with a role (`pid host server tcp://...`) would have read, on MK Studio's side, as a start time that does not match -
"pid reused" - and **a live server's lock would have been taken over**. It is reverted: MK Studio follows the published
protocol again, and reuses mkit-sql's pid-reuse test (a process that started after the lock file was written is not its
owner), which needs no change to the line format. The CI `interop` job caught the mismatch when it ran against mkit-sql's
newer code.

**The defect (both implementations).** In `takeLock`, after a failed exclusive create the code treats "the file is not
there" as "this folder cannot hold a lock" and returns "no lock needed" (mkit-sql: `if {[catch {::file lstat $lf st}]}
{ return "" }`). When a competitor deletes the stale lock *between* the failed create and that check, the process opens the
database **without a lock**, alongside the competitor that just took it. Reproduced by racing six processes for a stale
lock: MK Studio 2 winners in 1 of 40 rounds; mkit-sql 2-3 winners in 3 of 60 rounds at `fa3f77d` and 1 of 60 at
`210c3b7`. Fix: only a folder that refuses to create files means "run unlocked"; a vanished file means retry. MK Studio is
fixed with a deterministic regression test (a hook deletes the lock at exactly that moment). The fix for mkit-sql is in
`docs/mkit-sql-takelock.patch` (6 lines in `mkitsql/db.tcl`, against `210c3b7`): with it 60 stale-lock rounds were
clean and mkit-sql's own `tests/locking.tcl` still passes (75 checks).

Other findings: both implementations treated a *zombie* (killed, not yet collected by its parent) as a live owner on
Linux (`/proc/<pid>` still exists; MK Studio now checks the state letter - mkit-sql's `pidAlive` should too), and on
macOS/BSD `kill -0` fails with "not permitted" for a live process of another user (MK Studio treats that as alive).
`tests/test_lock_crash.tcl` kills a process at every step of acquiring, taking over and releasing and runs a chaos loop;
it is worth running against mkit-sql's implementation too (replace `lock_crash_child.tcl`'s `store::` calls).

## 3. Bulk mutation: two algorithms, same results, MK Studio's is as fast or faster

`tests/bench_mutation.tcl` runs identical statements on identical 200,000-row files through both engines (mkit-sql
through MK Studio's store, as installed) and compares the resulting tables row by row (all identical):

| statement | MK Studio (`store.tcl`) | mkit-sql (bulkMin 20000) | mkit-sql (bulkMin 1000) |
|---|---|---|---|
| `DELETE ... WHERE id % 2 = 1` (100,000 rows) | 4.5 s | 6.7 s | 7.5 s |
| `DELETE ... WHERE id % 50 = 0` (4,000 rows) | 5.9 s | 23.6 s | 11.2 s |
| `DELETE ... WHERE id > 190000` (contiguous) | 0.6 s | 0.4 s | 0.3 s |
| `UPDATE ... SET name = name \|\| 'xx'` (all rows) | 6.9 s | 18.4 s | 19.0 s |
| `UPDATE ... SET name = 'x' WHERE id % 20 = 0` | 6.8 s | 7.0 s | 11.9 s |
| `UPDATE ... SET val = val + 1` (numbers, in place) | 4.2 s | 5.5 s | 5.4 s |

(One machine, one run each; treat differences under ~30% as noise. mkit-sql's 2.3 s for a half-delete in its README is
a faster machine, not a different workload.)

What the numbers say:
- The row-rewrite step is not where mkit-sql loses time: with `bulkMin` at 1000 its 4,000-row delete improves 2x. The
  break-even for rebuilding on this machine is about 1,000 changes, so `bulkMin = 20000` leaves a 20x range in which it
  uses the quadratic path. Lowering it is the cheapest win.
- `UPDATE name = name || 'xx'` stays ~18 s in mkit-sql at either threshold, so its cost is in the update pipeline
  (spool + sort of the changed rows), not in the rebuild.
- The two rebuild strategies differ: MK Studio appends the changed *tail* after the last row and removes the old tail with
  one ranged delete (one copy, original untouched until the final step, cut back on failure); mkit-sql copies the whole
  table to a scratch table, empties the original and copies back (two copies; scratch kept for recovery on failure). Both
  are all-or-nothing and tested to produce identical tables.

**Recommendation:** keep one algorithm. In integrated mode mkit-sql already runs on `::store`; delegating
`deleteRowsSmart` and the string-`UPDATE` write phase to `::store::deleteRows` / `::store::updateRows` (which choose
in-place or tail rebuild at ~1,000 changes) removes the duplicate, and mkit-sql keeps its richer statement handling
(spooled/sorted updates, scratch recovery messages) around it. Until then, set `bulkMin` to ~1000.

## 4. Adopting the streaming-provider contract

An engine may return `provider <command prefix>` instead of `rows` (documented in `engine.tcl`). Run any engine's
providers through `tests/provider_contract.tcl`:

    source tests/provider_contract.tcl
    provider_contract::run "mkit-sql" $factory $mutate $restore

`factory` returns `{provider expectedRows}` for a query, `mutate` changes the data behind it, `restore` undoes that.
The suite checks slices, row ids, sorting (stable, every call), and the lifetime rules: stale after a change and then no
rows, frozen keeps exactly what it had, destroyed providers are safe. It passes for MK Studio's built-in dialect
(`tests/test_provider_contract.tcl`, 134 checks). Statements that change data should call `::mkql::lzFreezeAll` first (or
mkit-sql's equivalent), and a result derived from live data must compare `::store::generation` (see
`docs/CONCURRENCY.md`).
