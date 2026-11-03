# MK Studio

A SQL-Server-Management-Studio-style workbench for **Metakit** databases, written entirely in
Tcl/Tk and shipped as a **starpack**: one self-contained executable (Tcl, Tk and Metakit
included) that you can copy anywhere and run.

![main](docs/screenshots/main.png)

## What it does

- **Object Explorer** - databases, views, columns; subviews nested; view filter; Enter or double-click opens a view
- **Edit Rows** - spreadsheet-style editing with type validation; **every row is there** (a 500,000-row view opens in
  ~0.1 s and scrolls instantly - no paging), sort by any column, **undo / redo** (edits, added rows, deleted rows including
  their subview contents), double-click a `> N rows` cell to open a subview
- **Bytes columns** - size and hex preview in the grid; a hex viewer with export, replace-from-file and clear
- **Add Column** - one click from the data editor, or in the **Designer** with rename, retype and drop (a renamed column keeps its position)
- **Query windows** - syntax highlighting, completion, Find, multiple result tabs, cancel, error underlining; big results
  **stream**: a `SELECT *` over 500,000 rows opens in ~0.15 s and costs memory only for the rows on screen
- **Commit / Roll Back** - files are opened `-nocommit`: nothing reaches disk until you commit
- **Safety** - refuses files that aren't Metakit databases; read-only databases disable every write control;
  a second MK Studio asking to edit a database that is already open for editing is offered a read-only view instead
  (see *Crash safety and locking*)
- Dark, light and high-contrast themes; scales with display DPI; full keyboard operation (`F1` lists shortcuts)
- CSV import and export (export streams, so a whole big view can be exported), script save / open

More screenshots: [`docs/screenshots/`](docs/screenshots/) (all captured from the real app on real Metakit).

## The query language is pluggable

The UI never parses query text. It talks to one small seam, [`engine.tcl`](mkstudio.vfs/lib/app-mkstudio/engine.tcl),
which documents the exact contract (`::engine::parseScript`, `::engine::execute`, and the keyword / token /
cancel variables). `mkql.tcl` is a small built-in dialect so the app is usable on its own; a
standard-SQL-to-Metakit engine replaces it by redefining those two procs. The data grid and
designer use `store.tcl` directly and don't depend on the language at all.

    REAL_MK=1 tools/ext/tclkit-8.6.3-linux-x86_64 tests/engine_contract.tcl     # 38 checks against the contract

Edit the `stmts` array at the top of that test for your dialect and point it at your engine.

## License

MIT - see [`LICENSE`](LICENSE). The downloads contain Tcl/Tk, Metakit and other components under their own permissive
licenses: [`THIRD_PARTY_NOTICES`](THIRD_PARTY_NOTICES).

## Install

Download from the [releases page](https://github.com/atyr647/mkstudio/releases). **The files are not signed with a
certificate** - there is none behind this project - so each system asks you to confirm once:

| System | File | First start |
|---|---|---|
| Windows 10/11 | `MKStudio-<version>-windows-x64-setup.exe` (per-user, no administrator rights; Start menu entry, uninstaller, optional desktop shortcut and "Open with" for `.mk` files) or the single file `mkstudio-windows-x86_64.exe` | SmartScreen: *More info > Run anyway* |
| macOS | `MKStudio-<version>-macos-arm64.dmg` (Apple silicon) / `-x86_64.dmg` (Intel): drag to Applications | right-click the app > *Open* |
| Debian / Ubuntu | `mkstudio_<version>_amd64.deb` (`sudo apt install ./mkstudio_*.deb`) | |
| other Linux | `MKStudio-<version>-linux-x86_64.tar.gz`, then `sh install.sh` (installs into `~/.local`, no root) | |

`SHA256SUMS` lists every file. A checksum catches a damaged download, **not** a malicious one (whoever controls the GitHub
account controls the checksums too) - download only from the project's own releases page. `mkstudio --version` prints the
version; `mkstudio --selftest FILE` writes a one-line health check to FILE (CI uses it on every platform).

### Updates

*Help > Check for Updates...* asks the GitHub releases API for the newest release (one `GET`; the program name and version
are the only thing sent) using `curl`, `wget` or - on Windows - PowerShell, because the bundled Tcl has no TLS of its own. A
daily check at start-up is on by default and can be switched off in the same menu; it only writes a line in the status bar.
A stand-alone program in a writable folder can then **replace itself**: it downloads the new file, checks its SHA-256 against the
release's `SHA256SUMS` (no checksum tool = no automatic install), starts it once with `--selftest` and compares the version it
reports, and only then swaps it in; the old one stays beside it as `mkstudio.old` (rename it back to roll back). Anything
wrong at any step changes nothing. Installed copies (`.deb`, the `.app`, a program in a protected folder) are not touched:
the dialog opens the release page for the new installer. Pre-releases are only offered to someone already running one.
`tests/test_update.tcl` covers all of it against a fake release feed on disk: version order, JSON, choosing a release,
real download, wrong checksum, truncated download, a new program that does not start, one that reports the wrong version,
no checksum file, no file for this system, copies that must not replace themselves.

### Crash reports

An error that nothing handled is caught: a dialog says so, and a report is written to a local folder (*Help > Open Crash
Reports Folder*; `%LOCALAPPDATA%\MKStudio\crashes`, `~/Library/Logs/MKStudio`, `~/.local/state/mkstudio/crashes`).
It holds the version, system, Tcl/Tk versions, the error message, the call stack as **procedure names and line numbers**
and the last things the program did ("database opened", "query executed", "committed" - never SQL, rows or values); your
home folder and user name are replaced and database file names shortened. **Nothing is sent anywhere by the program.** The
dialog can copy the report or open a pre-filled GitHub issue in your browser; you read it and press submit yourself.
A crash nothing can catch (Metakit or Tk dying, a power cut) is noticed at the next start: every running copy keeps a small
marker file with its recent breadcrumbs, and a marker whose process is gone becomes a report. `tests/test_crash.tcl`
checks what is in a report (and, with a query full of fake secrets, what is not), rotation, the handler, and a really killed
process.

## Build it yourself

    tools/fetch-runtimes.sh             # download SHA1-verified tclkit runtimes into tools/ext/
    ./build.sh                          # Linux  -> dist/mkstudio-linux-x86_64
    ./build.sh all                      # + Windows (.exe)
    ./dist/mkstudio-linux-x86_64 [file.mk ...]

Binaries are not stored in git. `.github/workflows/build.yml` runs the whole test matrix on **Linux, Windows and two
macOS runners**, builds the starpacks and uploads them as artifacts (and attaches them to a release when you push a `v*` tag).
Wrapping needs no `sdx`: `tools/wrap.tcl` appends the application's Metakit payload to a runtime.

**macOS** has no usable prebuilt tclkit (the 2014 Tk 8.6.3 / 8.5.17 Mac builds crash on current macOS the first time a
window opens), so CI compiles a current Tcl/Tk 8.6 + Metakit kit with [KitCreator](https://kitcreator.rkeene.org/) on the Mac
runner (~8 min, cached), runs the tests with it, wraps the starpack with it and ad-hoc code-signs it
(Apple silicon refuses unsigned code). Download the Mac starpacks from the workflow's artifacts; `./build.sh macos`
explains how to do the same by hand.

Run from source (needs a Tk with Mk4tcl, e.g. a tclkit): `tclkit mkstudio.vfs/main.tcl [file.mk ...]`

## Verification

Every row below is something that was actually run; the CI badge-of-truth is the workflow itself.

| | status |
|---|---|
| All suites on **real Metakit** (Mk4tcl 2.4.9.7) | Linux, Tcl **8.6.3** and **8.5.17** - pass |
| **Windows** (`windows-latest`) | engine, contract, persistence, differential, crash-safety, grid and UI suites pass with the Windows tclkit; the built `.exe` launches and keeps running |
| **macOS** (`macos-15-intel` and `macos-latest`/Apple silicon) | the same suites pass with a KitCreator-built Tcl/Tk 8.6.16 (native Aqua); the starpack is wrapped, signed, payload-verified and launches |
| Real-world file (a tclkit's own boot database: subviews + binary columns) | opens, browses, hex view works |
| 500,000-row file | see the numbers below |
| Packaged Linux starpack | launches, opens a database, no errors; `--version` / `--selftest` answer correctly |
| Installers | `.deb` is installed, run and removed on a Linux runner; the tarball installs for one user; the Windows setup is installed silently, run, upgraded over itself and uninstalled on a Windows runner (Start menu entry, registry entries, files all checked); the macOS `.dmg` is mounted, signature verified, the app run and started as an app |
| Update path, crash reports, first-commit / checksum / backup | `tests/test_update.tcl` (93 checks incl. a real download from a fake feed), `tests/test_crash.tcl` (45), `tests/test_durability.tcl` (62), the Help menu / damaged-file / update dialogs in `tests/gui_logic.tcl` |
| HiDPI | verified with Tk scaling 2.0 on Linux; Windows/macOS DPI behaviour depends on the runtime's manifest |
| Screen readers | **not supported**: Tk has no accessibility API. Keyboard operation, visible focus and a high-contrast theme are provided instead |

Tests (all in `tests/`):

- `lint.tcl` - no proc shadows a Tcl/Tk command, ASCII-only sources, no 8.6-only commands, no unguarded X11-only keysyms
- `test_mkql.tcl`, `engine_contract.tcl` - the built-in dialect and the engine contract
- `test_engine_diff.tcl` - **thousands of random queries** (predicates, expressions, aggregates, grouping, ordering,
  limits) through the optimised executor and through the original simple one (`mkql_reference.tcl`); results must be
  identical (rows, values, types, row ids - and success or failure), also when the result is forced to stream lazily.
  DELETE / UPDATE are checked byte for byte (every column type, bytes, floats, subview rows) against an independent
  model through the in-place and the rebuild paths, and chains of bulk changes in one transaction must end in the same
  table either way. On the stand-in and on real Metakit under both Tcl versions
- `test_engine_semantics.tcl` - behaviour beyond "same rows": a query with one failing row fails with the *same message* or
  succeeds in both executors across a matrix of WHERE / LIMIT / ORDER BY / aggregate variants (also streamed); row order
  and ties; failed or cancelled `UPDATE` / `DELETE` / `INSERT` change nothing (also through the bulk-rebuild path);
  cancellation of scans and long column reads; a stale Cancel never poisons the next statement
- `test_provider_lifecycle.tcl`, `provider_contract.tcl` + `test_provider_contract.tcl` - the lifetime of streaming results
  and the cache (edits, restructuring, Roll Back, close/reopen, two databases, destroyed results; byte budget, LRU,
  multi-database eviction), and an engine-independent conformance suite any engine's providers can be run through
- `persist.tcl`, `test_crash_safety.tcl`, `test_power_loss.tcl`, `test_lock_protocol.tcl`, `test_lock_crash.tcl` - persistence,
  crash safety, power loss (synthesised and real-kill states, three ways of opening them), the write-lock protocol (incl. racing against mkit-sql's own implementation) and the lock under crashes (next section)
- `bench_mutation.tcl` - bulk `UPDATE`/`DELETE` of MK Studio's engine vs mkit-sql on identical files, results compared
- `test_grid.tcl` - the virtualised grid driven with real mouse and key events (100,000 rows in memory, a Metakit view,
  selection ranges, keyboard, sorting, the sort cache, editing in a scrolled grid, streaming results incl. staleness and
  freezing, empty results)
- `gui_logic.tcl` - the UI logic incl. every popup menu and undo
- `verify_payload.tcl`, `smoke_starpack.sh`, `bench.tcl`, and `shoot.tcl` for screenshots

A pure-Tcl `mk::` stand-in (`mock_mk4tcl.tcl`) lets most of the suite also run without Metakit; it is test-only.

## Crash safety and locking

`tests/test_crash_safety.tcl` starts a child process that rewrites a database and commits in a tight loop, **kills it
(SIGKILL / `taskkill /F`) at awkward moments**, and checks the file afterwards: every view and row present, every row
internally consistent, and all rows from *one* commit generation (a half-applied commit would show a mixture). Variants
cover data commits and structural commits (add / drop a column). Negative controls prove the verifier can fail (it flags
a hand-made torn commit, a corrupted value and a truncated file). It also checks that uncommitted edits never touch the
file (byte-identical after a kill) and that Roll Back restores cells, added/deleted rows and structure exactly.

**A correction.** An earlier version of this section said "never a torn or corrupt file". That was true of what the random
kills hit and **wrong as a claim**: a commit's writes happen in a burst of a few milliseconds at its end, the random kills
almost always landed before or after it, and a kill *inside* the burst leaves a file that Metakit opens as an **empty
database** - no error, no views (one macOS CI trial hit it by luck; strace fault injection hits it every time). See the next
section; this is now repaired when the database is next opened for writing, and tested at every write of a real commit.

## Power loss (best effort)

Killing a process is not a power cut: the operating system keeps what the process had already written. A power cut loses
whatever had not reached the disk, in any order, and there is no way to pull the plug from a test. What can be done:

1. **Look at what a commit really does.** `strace` of a Metakit commit: a few small in-place writes, then the new data and
   tail *appended* after the end of the file, and **last** an 8-byte header write at offset 0 that holds the new end of file.
   There is **no `fsync`, `fdatasync` or `msync` anywhere** - Metakit never forces anything to disk.
2. **Synthesise the files a power cut could leave** (`tests/test_power_loss.tcl`): run a commit, keep the file before (A) and
   after (B), find the 4 KiB pages (and 512-byte sectors) that differ, and build states in which any subset of them reached
   the disk - in write order (`ORDERED`, which is also what a *kill* leaves), the new header without the new data
   (`HEADER`), any subset (`REORDER`), any subset of sectors (`TORN`) - across seven kinds of commit (edit a cell, edit a
   number, append rows, delete rows, rewrite everything, add a column, change two views). Every file is opened in a separate
   process (Metakit can crash on garbage) and compared with the exact content of A and of B.
3. **Ground truth on Linux:** the same commit is *really killed* after its 1st, 2nd, 3rd ... Nth write to the database file
   with `strace` fault injection, and the file it leaves is judged. This is what validates the synthetic model.

Results (about 500 checks; Tcl 8.6 and 8.5; `raw` = Metakit alone):

| states a power cut or kill can leave | raw Metakit | + cut back an unfinished append | + the commit record (what MK Studio does) |
|---|---|---|---|
| write-ordered prefixes (= a kill mid-commit), 35 | 7 right, **28 an empty database** | 35 old state | 35 old state |
| new header, data missing / partial, 70 | 19 right, **51 wrong** | 19 right, 51 wrong | **70 old state** |
| any subset of 4 KiB pages, 175 | 59 right, **116 wrong** | 112 right, 63 wrong | **175 old state** |
| any subset of 512-byte sectors, 126 | 27 right, **94 wrong, 3 crashes, 2 hangs** | 80 right, 42 wrong, 4 hangs | **126 old state** |
| real kills at 18 points of a real commit | 2 right, **16 empty databases** | | **18 old state** |

"Wrong" means the file opened (or Metakit crashed or hung) but did not hold exactly the old or exactly the new state - most
often an empty database, silently. So **Metakit alone is not crash-safe in the middle of a commit, and not power-loss safe
at all.** What MK Studio now does (`store.tcl`):

- before a commit starts it writes `<file>.commit` (the committed header and size) and, where the system has `sync`
  (Linux, macOS), forces it and the file to disk; after the commit it forces the file to disk and removes the record;
- when a database is opened *for writing* (with the lock held) and a record is found, the header and size are put back: the
  database is exactly what it was before that commit; with no record, a file longer than its header says is cut back to the
  header's offset. The user is told ("An unfinished commit was undone ...");
- read-only opens never repair anything (they may see the unfinished state).

Cost: a commit takes about 0.25 s longer on a 30 MB database (the two `sync`s).

**Further hardening** (`tests/test_durability.tcl`):

- **Windows now forces the data out too**: `FlushFileBuffers` through PowerShell (`FileStream.Flush($true)`; one short PowerShell
  start per stage, so two per commit). If PowerShell cannot be started this quietly stays
  best-effort, as before. CI asserts on a real Windows runner that the flush happened. macOS `sync` flushes the operating
  system's cache but cannot reach the drive's own cache (`F_FULLFSYNC` is not available from Tcl).
- **The first commit of a new database is protected**: the record then says "empty", and a record found at the next open
  makes the file empty again instead of leaving a half-written first save (real kills at every write of a first commit:
  all come out empty or complete, never half).
- **Silent corruption is detected**: after every commit `<file>.sum` stores a CRC-32, the size and the modification time of
  the finished file. At the next open for writing the sum is checked - but only if size and time still match (a file another
  program legitimately changed just gets a new baseline). Same size and time but different content is what a bad sector or
  bit rot looks like: MK Studio does not touch the file, says so, and offers the backup.
- **A backup of the file as it was before the first commit of an editing session** is kept as `<file>.bak` (never replaced
  by a copy that fails the check). *Restore Backup* keeps the damaged file as `<file>.damaged`.
- Cost (measured): the CRC of 100 MB takes 0.15 s on every commit, the backup copy 0.35 s once per editing session - a 29 MB database
  adds about 40 ms per commit. The backup needs as much free disk space as the database.
- Not covered: files larger than 512 MB (no checksum or backup - the limit is `store::sumLimit`), damage that happens
  *before* the first baseline, damage that keeps size and time and is also in `.sum` itself.

**Limits - please read.** The result is "the last confirmed commit, or the one before it, never a mixture", *given* the
model: pages reach the disk in any order, an 8-byte write is atomic (it lies in one sector), and `sync` really forces data
out. It does not cover a disk that lies about having written (some cheap SSDs and USB sticks), a filesystem that loses a
whole file, or data lost from a commit that was already confirmed - and Windows has no `sync` command, so there the
flush goes through PowerShell (see below) and is only as good as that. A commit that was in flight when the power
failed is lost (rolled back), by design: it was never confirmed to the user. `mkit-sql` on its own storage layer
(`db.tcl`) does not have this protocol; in MK Studio it shares `store.tcl`, so it does.

What it **did** find: Metakit does no locking. A second process that opens the file *while another commits* sometimes
sees a mixed or unreadable state (between under 1% and 12% of the probe's reads, depending on timing), and two writers
can overwrite each other. So there is one concurrency policy, written down in
[`docs/CONCURRENCY.md`](docs/CONCURRENCY.md), for every component that touches a database (this app, the SQL engine,
a server): an advisory `<file>.lock` (`pid host [role [endpoint]]`) that a writer takes with an atomic exclusive create
and holds while it has the file open for writing.

- a second MK Studio asked to edit it gets *"Database in use ... Open Read-Only / Cancel"* (read-only is always allowed,
  with a warning that the other process's commits may show up half-written);
- a lock left behind by a crashed process is recognised (its pid is gone) and taken over, so a crash never locks you out;
  a lock from another machine (a network share) is respected, since its liveness can't be checked;
- a long-lived owner such as a server announces itself (`role`, `endpoint`) so clients are told who to talk to;
- a process that started after the lock file was written (a reused pid) is not its owner; a zombie is not running;
- a process only ever removes *its own* lock.

`tests/test_lock_protocol.tcl` checks this against hand-written independent implementations of the protocol and races six
real processes for a free lock and for the same stale lock - half of them mkit-sql's own implementation when
`MKITSQL_DIR` is set. `tests/test_lock_crash.tcl` kills a process at every step of acquiring, taking over and releasing,
then runs a chaos loop (eight processes, random SIGKILLs, mutual exclusion checked from inside: 0 violations in ~400
acquisitions per run). Between them they found three real defects, all fixed: several processes could each "take over"
the same stale lock; a process whose stale lock was deleted by a competitor at the wrong instant carried on *without any
lock* (this one is also in mkit-sql - see [`docs/mkit-sql-integration.md`](docs/mkit-sql-integration.md) and the 7-line
patch there); and a zombie (killed, not yet collected) counted as a live owner. mkit-sql implements the same published protocol;
an attempt of mine to change it unilaterally (`670fc86`) was caught by the interop job and reverted.

The lock only protects cooperating programs - others that open the file ignore it - and relies on `O_EXCL`, which is
reliable on local file systems and modern NFS. Read-only folders skip the lock. Derived data (sorted orders, column
copies, lazy results) is guarded by a per-database *generation* that every change and every Roll Back advances.

## Performance and limits (500,000 rows, 29 MB, Linux)

| operation | now | was |
|---|---|---|
| open file, list views / layout | ~40 ms | |
| open a view in the editor / jump to any row | ~0.1 s / ~4 ms | 0.16 s for the first 5,000 rows only |
| `SELECT * FROM big` (all 500,000 rows, streamed) | ~0.2 s, ~80 MB | 100,000-row cap, seconds, ~hundreds of MB |
| `SELECT ... ORDER BY <column>` over all rows (streamed) | ~1.2-2.8 s | |
| `SELECT ... LIMIT 100` | ~6 ms (warm) | ~10 ms |
| `WHERE` on `=`, `<`, `<=`, `>`, `>=`, `BETWEEN`, `IN`, text `=` (pushed into Metakit) | 0.15-0.35 s | ~6.5 s |
| `WHERE` that can't be pushed (`LIKE`, expressions), full scan | ~2 s | ~6.5 s |
| `SELECT COUNT(*)` | ~1 ms | ~6 s |
| `SUM / MIN / MAX` over everything; `GROUP BY` | ~2.5 s; ~2.5 s | ~7 s; ~7.2 s |
| `ORDER BY <number column> ... LIMIT n` | ~1.2 s first time, ~60 ms after | ~11.5 s (41 s originally) |
| click a column header in the editor (sorts all 500,000 rows) | ~1.5 s first time, instant after (cached) | sorted the loaded page only |
| select all + copy 500,000 rows (34 MB) | ~10 s | |
| `UPDATE` 10,000 rows of a string column (contiguous or scattered) | **~9-10 s** | ~24 s |
| `DELETE` 10,000 scattered rows | **~10 s** | ~32 s |

Mutations are still the slowest thing here, and the limit is **Metakit's design**: columns are stored contiguously,
so rewriting a variable-length value or deleting a row shifts everything after it (2-4 ms each on 500,000 rows,
growing with the data behind the row), while appending costs ~3 us per row. Past about a thousand changes the
store therefore rebuilds the affected tail of the view instead - append the changed copy after the last row, then
remove the old tail with one ranged delete - for a 2.5-3x gain; the cost becomes proportional to the rows from the first
change to the end of the view, not to the number of changes. Changes that touch only fixed-width columns (numbers) were
never slow, and a run of consecutive deletes is one call. If the copy fails the view is cut back to its old size, so
nothing is half-changed. The app keeps the UI responsive, skips writes that change nothing, and Roll Back
undoes a whole run (and is fast). Going much beyond this needs a different storage layout, not a smarter loop.

**Compared with mkit-sql's rebuild** (200,000 rows, identical statements and files, results identical row for row):
a 100,000-row scattered delete 4.5 s vs 6.7 s; 4,000 scattered deletes 5.9 s vs 23.6 s (mkit-sql rebuilds only from 20,000
changes; the break-even is ~1,000); `UPDATE name = name || 'xx'` on every row 6.9 s vs 18.4 s (its cost is the update
pipeline, not the rebuild). Details and a recommendation to keep one algorithm: `docs/mkit-sql-integration.md`.

How the speed-ups work, and their limits:

- **The grid is virtualised.** The treeview holds only the rows that fit in the window (about 30); scrolling re-labels
  them. Rows come from a data source: query results from memory, a Metakit view read on demand (a small cache), or an
  engine-supplied streaming source. Selection is a list of row *ranges* (so "select all" of 500,000 rows is free), and
  the scrollbar, wheel, keyboard and drag-selection are the grid's own. Scrolling is by whole rows, like the native treeview.
- **Big results stream.** A plain `SELECT` (no aggregates, no `DISTINCT`) with 20,000+ rows is kept as a *list of row
  ids* (about 30 bytes a row) and projected as the grid asks for rows; `ORDER BY` plain stored columns is done on the
  ids with cached column copies. Because a streamed result reads live data, it is guarded by the database's generation:
  if the data changes some other way (an edit in a data tab) a banner says the result is out of date and to run the query
  again, and when a statement in the same window changes data, the results are first frozen into memory so they keep
  showing what the query returned; closing the database freezes them too, and a result too big to freeze goes stale for
  good - a generation number is never reused, so reopening the file cannot bring it back to life. The unsorted-result cap (100,000 rows) does not apply to streamed results. Sorting a
  streamed result by a column header evaluates that column for every row (about as slow as materialising it).
- **Sorting and repeated queries.** Column copies and sort orders are cached per database generation in a **byte budget**
  shared by all open databases (default 256 MB, `store::cacheConfigure -budget MB` or `MKS_CACHE_MB`, 0 turns it off;
  an estimate of the Tcl-object size, least-recently-used eviction, a database's entries dropped when it closes), so
  flipping a sort direction, sorting again, or running another `ORDER BY ... LIMIT` on the same column is instant.
  A million-row sort order costs roughly 50 MB of Tcl objects plus the column copy it was built from. Million-row sorts are still a full pass the first time (~3 s a million); Metakit has no indexes, so the cache is
  the "index" - it lives for the session and is discarded the moment the data changes.
- **Filters are answered inside Metakit** (`mk::select`) when a top-level `AND` term has the right shape. The whole
  `WHERE` still runs on the surviving rows unless every term was pushed exactly.
- **Statements are all-or-nothing.** A failed or cancelled `UPDATE`, `DELETE` or `INSERT` changes nothing (the original
  executor left the rows written before the failure; that was a defect, so this is deliberately *not* equivalent to it).
  Cancel is honoured while reading and evaluating, never while writing.
- **Strict equivalence.** Pushdown, top-k, `COUNT(*)` and streaming look at fewer rows than a plain scan would, which
  could hide an error such as `text * 2` or a division by zero on a row the plain scan reaches. They are therefore only
  used when `mkplan.tcl` can *prove* that nothing they skip can raise (type-aware: stored number columns, constant
  non-zero divisors, integer-only `%`, argument checks for functions). Anything else takes the plain path. The
  differential test enforces this: the optimised executor returns the same rows, values and types - and fails exactly
  when the simple one fails (it may name a different offending row in the message).
- **These optimisations belong to the built-in dialect.** If you replace it with your own SQL engine (see below) its speed
  is yours to design; `store.tcl` offers `select`, `fetch`, `fetchAt`, `column` and the cache for exactly that, and the
  engine seam lets any engine return a streaming `provider` instead of rows. The grid and the data editor don't depend on
  the query language at all.

## Notes on Metakit

There is no NULL (it means the empty string). A view you drop stays listed by Metakit until commit, so views
with an empty layout are treated as gone. `mk::view layout` on a subview path returns the *top-level* layout, so
`store.tcl` walks the nested definition itself. `mk::row insert` only takes a count, so restoring a row inserts a
blank one and fills it. `mk::select -exact` on a *double* column compares the text ("7.0" is not "7"), so double
equality is expressed as a numeric range. `mk::select -sort` is not stable. Each of these is covered by a test.

## Layout

```
mkstudio.vfs/main.tcl                 entry point (starkit)
mkstudio.vfs/lib/app-mkstudio/
    store.tcl     the ONLY file that calls mk::*  (incl. the advisory write lock)
    engine.tcl    the query-language seam (documented contract)
    mkql.tcl      built-in stand-in dialect: parser, binder, value semantics
    mkplan.tcl    its fast execution path: pushdown, compiled expressions, streaming aggregates, lazy results
    version.tcl   the version number (one place) and semantic-version comparison
    update.tcl    update check, checksum-verified download, self-replacement (no Tk)
    crash.tcl     error handler, crash reports, unexpected-end detection
    theme icons menus widgets grid editor explorer docs app
packaging/     NSIS installer, .deb/.tar.gz, macOS .app/.dmg, icons (tools/make-icons.py draws them)
tests/  tools/  build.sh  .github/workflows/build.yml
RELEASE_NOTES.md       the text of the current release
docs/CONCURRENCY.md    the shared write-lock / generation policy (for mkit-sql or a server)
```
