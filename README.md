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
- **Bytes columns** - size and hex preview in the grid; a hex viewer with export, replace-from-file and clear. Only the size and
  the bytes on screen are read (a 1 GB value costs nothing to show), and export streams
- **Ribbon kits** (`.kit`) - a **Kit** tab next to the raw views: the manifest (identity, needs, permission requests, entry points,
  effects, seal and signer), the file tree with sizes, codecs and chunk counts, a preview of text, PNG/GIF images and other bytes,
  **Verify** (every chunk, the image, the header and the root hash against the seal, in a separate process, with progress and
  Cancel), **Extract** a file, a folder or everything, and a system kit's embedded image (filesystem, offset, dm-verity root).
  Kits are opened read-only and nothing is written next to them. The same kit is queryable as `kit.*` tables in SQL
- **Add Column** - one click from the data editor, or in the **Designer** with rename, retype and drop (a renamed column keeps its position)
- **Query windows** - standard SQL (mkit-sql: joins, CTEs, window functions, `MERGE`, ...), syntax highlighting, completion, Find,
  multiple result tabs, cancel, error underlining. A result is limited to 100,000 rows in memory (the window says when it was cut);
  the built-in dialect (`MKS_ENGINE=mkql`) streams results of any size instead - see *Performance and limits*
- **Commit / Roll Back** - files are opened `-nocommit`: nothing reaches disk until you commit
- **Safety** - refuses files that aren't Metakit databases; Metakit data after a header (a starkit, a starpack, a kit) is found
  from the end of the file, as Metakit itself finds it, and opened read-only; read-only databases disable every write control;
  a second MK Studio asking to edit a database that is already open for editing is offered a read-only view instead
  (see *Crash safety and locking*)
- Dark, light and high-contrast themes; scales with display DPI; full keyboard operation (`F1` lists shortcuts)
- CSV import and export (export streams, so a whole big view can be exported), script save / open

More screenshots: [`docs/screenshots/`](docs/screenshots/) (all captured from the real app on real Metakit).

## The query language: standard SQL (mkit-sql), behind a pluggable seam

Queries are **standard SQL** run by [mkit-sql](https://github.com/atyr647/mkit-sql) 0.4.2 (joins, CTEs incl. `WITH RECURSIVE`,
window functions, `MERGE`, `LATERAL`, `ROLLUP/CUBE`, dates and intervals, bounded-memory spilling, `EXPLAIN`; the language is
documented in its `docs/SQL.md`). It is **vendored** in [`mkstudio.vfs/lib/mkitsql`](mkstudio.vfs/lib/mkitsql) at a known commit
(named in its `SOURCE` file; `tools/sync-mkitsql.sh` updates the copy and CI checks it byte for byte against that commit), so a
release is exactly what was tested. Inside MK Studio mkit-sql runs on `store.tcl`: one set of open files, one lock, one commit
protocol - a change made by a statement is a change in the open database, saved and rolled back with the same buttons.

The UI never parses query text. It talks to one small seam, [`engine.tcl`](mkstudio.vfs/lib/app-mkstudio/engine.tcl),
which documents the exact contract (`::engine::parseScript`, `::engine::execute`, and the keyword / token /
cancel variables); mkit-sql plugs in by redefining those two procs (`mkitsql/engine_studio.tcl`). The data grid and
designer use `store.tcl` directly and don't depend on the language at all. `mkql.tcl`, the small dialect MK Studio started with,
stays in the tree as a stand-in and a reference for the tests; start the program with `MKS_ENGINE=mkql` to use it.

    REAL_MK=1 xvfb-run -a tclkit tests/run.tcl tests/test_engine_wiring.tcl     # mkit-sql really is the engine: parse, run, commit, lock
    REAL_MK=1 tools/ext/tclkit-8.6.3-linux-x86_64 tests/engine_contract.tcl     # the contract itself (the built-in dialect)

CI additionally runs mkit-sql's own studio-side suites against *this* `store.tcl` (contract, integration, locking, commit
failure, damaged files, power loss, checksum attestation, review regressions) on the pinned commit - which must pass, and
on its newest commit - which may fail and is the early warning that the two repositories have drifted apart.
What was found when the two were put together, and what is still different: [`docs/mkit-sql-integration.md`](docs/mkit-sql-integration.md).

## License

MIT - see [`LICENSE`](LICENSE). The downloads contain Tcl/Tk, Metakit and other components under their own permissive
licenses: [`THIRD_PARTY_NOTICES`](THIRD_PARTY_NOTICES).

## Install

Download from the [releases page](https://github.com/atyr647/mkstudio/releases). **The files are not signed with a
certificate** - there is none behind this project - so each system asks you to confirm once:

| System | File | First start |
|---|---|---|
| Windows 10/11 | `MKStudio-<version>-windows-x64-setup.exe` (per-user, no administrator rights; Start menu entry, uninstaller, optional desktop shortcut and "Open with" for `.mk` files) or the single file `mkstudio-windows-x86_64.exe` | SmartScreen: *More info > Run anyway* |
| macOS | `MKStudio-<version>-macos-arm64.dmg` (Apple silicon) / `-x86_64.dmg` (Intel): drag to Applications | macOS 15 and later: try to open it once, then *System Settings > Privacy & Security > Open Anyway*; macOS 14 and earlier: right-click the app > *Open* |
| Debian / Ubuntu | `mkstudio_<version>_amd64.deb` (`sudo apt install ./mkstudio_*.deb`) | |
| other Linux | `MKStudio-<version>-linux-x86_64.tar.gz`, then `sh install.sh` (installs into `~/.local`, no root) | needs glibc 2.28 or newer (RHEL 8+, Debian 10+, Ubuntu 18.10+) and the X11, Xft and fontconfig libraries every desktop has |

`SHA256SUMS` lists every file. A checksum catches a damaged download, **not** a malicious one (whoever controls the GitHub
account controls the checksums too) - download only from the project's own releases page. `mkstudio --version` prints the
version; `mkstudio --selftest FILE` writes a one-line health check to FILE (CI uses it on every platform).

### What "unsigned" costs you on macOS

The app is not notarized (that needs a paid Apple Developer ID), so the first-start confirmation above is unavoidable, and
the bundle is not sealed either. Consequences, as far as they are known (the macOS behaviour below is Apple's documented
behaviour, not something tested here):

- Nothing protects the program's code: a starpack's Tcl code is appended after the signed part of the executable, so it can be
  changed without invalidating any signature. That is true of every starpack, on every system.
- `codesign --verify` on the app reports a problem and `spctl --assess` rejects it; that is expected for any ad-hoc app and
  would be rejected anyway without notarization.
- The identity of an ad-hoc program changes with every build, so macOS may ask again for access to Documents, Desktop or
  Downloads after an update.
- Run it from /Applications (drag the app there from the disk image): from the Downloads folder macOS runs a quarantined app from a
  temporary read-only copy.
- Features that require a signed bundle (sandboxing, keychain sharing, Sparkle-style auto-update, some login-item
  APIs) are unavailable; MK Studio uses none of them. The in-app updater therefore opens the release page instead of replacing
  a `.app`.
- Not known: whether a future macOS will insist on sealed bundles. A sealable layout exists (ship the unmodified runtime as the
  executable and the application as a real folder inside the bundle); it would also allow signing and notarization if you ever get a
  Developer ID.

### Updates

*Help > Check for Updates...* asks the GitHub releases API for the newest release (one `GET`; the program name and version
are the only thing sent) using `curl`, `wget` or - on Windows - curl.exe or PowerShell (always the copies in the system folder, never one found next to the program), because the bundled Tcl has no TLS of its own. A
daily check at start-up is on by default and can be switched off in the same menu; it only writes a line in the status bar.
A stand-alone program in a writable folder can then **replace itself**: it downloads the new file, checks its SHA-256 against the
release's `SHA256SUMS` (no checksum tool = no automatic install), starts it once with `--selftest` and compares the version it
reports, and only then swaps it in; the old one stays beside it as `mkstudio.old` (rename it back to roll back). Anything
wrong at any step changes nothing. **On Windows a running starpack cannot be renamed or replaced** (it keeps its own file open; the
first CI run of the real self-update test failed with "permission denied" exactly there), so the verified download is staged
next to the program as `mkstudio.exe.new` and a small hidden PowerShell helper (started in the background, waiting for as long
as MK Studio runs) installs it the moment MK Studio closes - or closes and restarts it if you choose *Close and Restart*. Installed copies (`.deb`, the `.app`, a program in a protected folder) are not touched:
the dialog opens the release page for the new installer. Pre-releases are only offered to someone already running one.
Anonymous GitHub API requests are limited to 60 an hour per network address; if that is used up the check says so in plain words.
`tests/test_update.tcl` covers all of it against a fake release feed on disk (and `tests/test_update_live.tcl` against the real release, on every OS in CI): version order, JSON, choosing a release,
real download, wrong checksum, truncated download, a new program that does not start, one that reports the wrong version,
no checksum file, no file for this system, copies that must not replace themselves.

### Crash reports

An error that nothing handled is caught: a dialog says so, and a report is written to a local folder (*Help > Open Crash
Reports Folder*; `%LOCALAPPDATA%\MKStudio\crashes`, `~/Library/Logs/MKStudio`, `~/.local/state/mkstudio/crashes`).
It holds the version, system, Tcl/Tk versions, the error message, the call stack as **procedure names and line numbers**
and the last things the program did ("database opened", "query executed", "committed" - never SQL, rows or values); your
home folder and user name are replaced, every file path is cut to `<folder>/<file>` plus its extension, and quoted text in an error
message (where a value could slip in) is removed. **Nothing is sent anywhere by the program.** The
dialog can copy the report or open a pre-filled GitHub issue in your browser; you read it and press submit yourself.
A crash nothing can catch (Metakit or Tk dying, a power cut) is noticed at the next start: every running copy keeps a small
marker file with its recent breadcrumbs, and a marker whose process is gone becomes a report. `tests/test_crash.tcl`
checks what is in a report (and, with a query full of fake secrets, what is not), rotation, the handler, and a really killed
process.

## Build it yourself

    tools/fetch-runtimes.sh             # the OLD prebuilt tclkits (2014, SHA1-verified): enough to run the tests and to build
    ./build.sh                          # Linux  -> dist/mkstudio-linux-x86_64   (on the old runtime unless a current one is in tools/ext/)
    ./build.sh all                      # + Windows (.exe)
    ./dist/mkstudio-linux-x86_64 [file.mk ...]

**The released programs are built on a current Tcl/Tk 8.6.18 + Metakit runtime** (the Metakit is the author's fork, see "Files over 2 GiB" below) that CI compiles with
[KitCreator](https://kitcreator.rkeene.org/) (a pinned revision, zlib 1.3.1; `tools/build-kit.sh`; each runtime is cached
until that script changes): **Linux** in a glibc 2.28 container (so it runs on RHEL 8+, Debian 10+, Ubuntu 18.10+ and
newer; it links the system's X11/Xft/fontconfig, as every Tk program does), **Windows** cross-built with mingw-w64 (the
.exe needs no runtime DLLs - CI checks that), **macOS** natively on each Mac. `MKS_REQUIRE_CURRENT=1 ./build.sh all`
refuses to fall back to the 2014 runtimes (CI sets it). The 2014 tclkits (Tcl 8.6.3 with zlib 1.2.8, and 8.5.17) remain as
the second and third runtime the test suites run on, because MK Studio's source stays compatible with Tcl 8.5.

Binaries are not stored in git. `.github/workflows/build.yml` runs the whole test matrix on **Linux, Windows and two
macOS runners**, builds the starpacks and uploads them as artifacts (and attaches them to a release when started with a
release tag). Wrapping needs no `sdx`: `tools/wrap.tcl` appends the application's Metakit payload to a runtime.

On macOS `codesign` cannot sign a starpack again - its payload follows the Mach-O image - so it keeps the ad-hoc signature the
linker gave the runtime, which is what Apple silicon checks; no certificate is involved. `./build.sh macos` explains how to
build the Mac starpack by hand.

Run from source (needs a Tk with Mk4tcl, e.g. a tclkit): `tclkit mkstudio.vfs/main.tcl [file.mk ...]`

## Verification

Every row below is something that was actually run; the CI badge-of-truth is the workflow itself.

| | status |
|---|---|
| All suites on **real Metakit** (Mk4tcl 2.4.9.7) | Linux, on the current **8.6.18** runtime, the 2014 **8.6.3** and **8.5.17** - pass |
| **Windows** (`windows-latest`) | engine, contract, persistence, differential, crash-safety, durability, update, grid and UI suites pass with the current Windows runtime (8.6.18, cross-built); the built `.exe` launches and keeps running; a running copy is really replaced by the update helper, from a folder with spaces, parentheses and an accented letter in its name |
| **macOS** (`macos-15-intel` and `macos-latest`/Apple silicon) | the same suites pass with a KitCreator-built Tcl/Tk 8.6.18 (native Aqua); the starpack is wrapped on that runtime, payload-verified and launches |
| mkit-sql as the query language | `tests/test_engine_wiring.tcl` on every OS; mkit-sql's own studio-side suites (contract, integration, locking, commit failure, damage, power loss, checksum, review regressions) against this program's `store.tcl`, on the pinned commit, in CI |
| Real-world file (a tclkit's own boot database: subviews + binary columns) | opens, browses, hex view works |
| 500,000-row file | see the numbers below |
| Packaged Linux starpack | launches, opens a database, no errors; `--version` / `--selftest` answer correctly |
| Installers | `.deb` is installed, run and removed on a Linux runner; the tarball installs for one user; the Windows setup is installed silently, run, upgraded over itself and uninstalled on a Windows runner (Start menu entry, registry entries, files all checked); the macOS `.dmg` is mounted, signature verified, the app run and started as an app |
| Update path, crash reports, first-commit / checksum / backup | `tests/test_update.tcl` (120 checks incl. a real download from a fake feed and a **live check against the real GitHub release** on every OS), `tests/test_crash.tcl` (66), `tests/test_durability.tcl` (112), the Help menu / damaged-file / update dialogs in `tests/gui_logic.tcl` |
| HiDPI | verified with Tk scaling 2.0 on Linux; Windows/macOS DPI behaviour depends on the runtime's manifest |
| Screen readers | **not supported**: Tk has no accessibility API. Keyboard operation, visible focus and a high-contrast theme are provided instead |

Tests (all in `tests/`):

- `lint.tcl` - no proc shadows a Tcl/Tk command, ASCII-only sources, no 8.6-only commands, no unguarded X11-only keysyms
- `test_engine_wiring.tcl` - mkit-sql is the engine behind the seam: its version is the vendored one, parse offsets and syntax-error codes
  reach the editor, a statement's change lands in the store's open database and is committed, rolled back, locked and checksummed there
- `test_mkql.tcl`, `engine_contract.tcl` - the built-in dialect and the engine contract (these and the next five suites test the
  built-in dialect, which the tests pin with `MKS_ENGINE=mkql`; mkit-sql has its own, much larger test suite in its repository)
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
- `test_mksync.tcl` - the native flush library: it loads through the same `pkgIndex.tcl` the starpack carries (into Tcl 8.5, 8.6.3 and the
  current runtime), flushes files and folders, skips a missing path, handles names with spaces, accents, CJK and brackets, a path beyond 260
  characters, a file another channel has open with unwritten data, and falls back to a program when switched off; CI runs it on all three
  systems and checks that each starpack carries the library byte for byte and reports `flush native (...)` by itself
- `blockdev_crash.sh` (+ `blockdev_workload.tcl`, `blockdev_crash.py`, `blockdev_check.tcl`, workflow `blockdev.yml`) - the **block-level crash
  test**: ext4, xfs and btrfs on a Linux device-mapper `dm-log-writes` device that records every write in the order the disk completes
  them (its worst case for a power failure); MK Studio makes a series of real commits on it (a new database, edits, growth, a second editing
  session with its backup) with the durable flushes on; the log is then replayed onto a copy of the original disk and the power is "cut"
  after up to 400 different writes; each resulting disk state is mounted (the file system recovers its journal), the database is opened as
  MK Studio opens it, and must hold exactly one of the commits - never older than the last one acknowledged, never a mixture, never reported damaged
- `test_update_live.tcl` - the update path against the *real* GitHub release (real API, download, checksum, the published program started)
- `soak_lock_chaos.tcl` - the lock chaos test repeated and measured (the manual "lock soak" CI job)
- `bench.tcl` - the 500,000-row scale benchmark below, for either engine; `bench_mutation.tcl` - bulk `UPDATE`/`DELETE` of MK Studio's
  engine vs mkit-sql on identical files, results compared
- `test_grid.tcl` - the virtualised grid driven with real mouse and key events (100,000 rows in memory, a Metakit view,
  selection ranges, keyboard, sorting, the sort cache, editing in a scrolled grid, streaming results incl. staleness and
  freezing, empty results)
- `gui_logic.tcl` - the UI logic incl. every popup menu and undo
- `test_kit.tcl` - Ribbon kits: Metakit data after a header is recognised (a starkit, a kit) while text, a file with fake tails
  and a truncated kit stay refused; bytes cells and export read sizes and ranges, never the whole value (reads counted); the Kit tab
  on Ribbon's golden kits (tree, previews, manifest, verify in a child process incl. a damaged kit and Cancel, extraction, a system
  kit's image page, `kit.*` SQL), and nothing is written next to a kit
- `verify_payload.tcl`, `smoke_starpack.sh`, and `shoot.tcl` for screenshots
- what no test can do is in [`docs/QA-CHECKLIST.md`](docs/QA-CHECKLIST.md): the hour of manual checks before a release; what is still open, and whether it is worth doing: [`docs/OPEN-ITEMS.md`](docs/OPEN-ITEMS.md)

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

- before a commit starts it writes `<file>.commit` (the committed header and size) and forces it and the file to disk (the native
  flush below; without it `sync` on Linux and macOS, PowerShell on Windows); after the commit it forces the file to disk, then rewrites the record to describe the
  *finished* file and forces that, then removes it - so a record that cannot be removed (a virus scanner holds it) or whose
  removal is lost in a power cut can never undo a commit that was reported as done;
- when a database is opened *for writing* (with the lock held) and a record is found, the header and size are put back: the
  database is exactly what it was before that commit; with no record, a file longer than its header says is cut back to the
  header's offset. The user is told ("An unfinished commit was undone ...");
- read-only opens never repair anything (they may see the unfinished state).

Cost: with the native flush a commit adds a few milliseconds on Linux and Windows (the time the drive itself needs); without it about 0.25 s on a 30 MB database
on Linux and macOS (the `sync` programs) and one to two seconds on Windows (PowerShell, see below).

**Further hardening** (`tests/test_durability.tcl`):

- **The flush is a small native library** (`native/mksync/mksync.c`, about 150 lines of C, one command: `mksync::flush`), built in CI for
  each system and carried inside the starpack: `fsync` on Linux (the file and its folder), **`fcntl(F_FULLFSYNC)` on macOS** - the call that also
  empties the drive's own write cache, which `sync` cannot reach - and `FlushFileBuffers` on Windows. No program is started: a flush costs
  milliseconds, and nothing that looks like malware (a hidden PowerShell with an encoded command) runs on a save. It is linked against the Tcl *stubs*, so
  one binary loads into every Tcl 8.5 / 8.6 / 9 of its platform, and **it is optional**: where it cannot be loaded (a checkout, a
  `noexec` temp folder) the program falls back to what it used to do and loses speed, not safety. `MKS_NATIVE=0` forces the fallback; `mkstudio --info FILE` writes which one is in use ("flush native (fsync)"). An error from the native call (the system or the disk reported a
  failure) is reported as a failed flush, never retried into a success.
- **The fallback on Windows**: `FlushFileBuffers` through PowerShell (`FileStream.Flush($true)`). **PowerShell has to be
  started through `cmd /c` with the script as `-EncodedCommand`**: started straight from the program it does nothing at all (exit
  status 0, no output, no effect - measured on real runners; a Windows GUI program has no console and Tcl starts console programs
  without one for it). Release 1.0.0-rc.1 started it the straight way, so **its Windows flush never ran** and every check that
  only looked at the exit status still passed; `tests/test_durability.tcl` now makes PowerShell write a file and fails if the file
  does not appear. The price is real: 0.4-0.7 s per PowerShell start (measured on the CI runners: 358 ms, 703 ms), three starts per save (CI measured 2.2 s per start on a loaded Windows runner, against 0.1 ms for the native call). If PowerShell cannot be started the flush stays best-effort and `syncDisk` says so.
  The fallback on macOS, `sync`, flushes the operating system's cache but cannot reach the drive's own cache.
- **The first commit of a new database is protected**: the record then says "empty", and a record found at the next open
  makes the file empty again instead of leaving a half-written first save (real kills at every write of a first commit:
  all come out empty or complete, never half).
- **Silent corruption is detected**: after every commit `<file>.sum` stores a CRC-32, the size and the modification time of
  the finished file. At the next open for writing the sum is checked - but only if size and time still match (a file another
  program legitimately changed just gets a new baseline). Same size and time but different content is what a bad sector or
  bit rot looks like: MK Studio does not touch the file, says so, and offers the backup. The checksum file is removed in the same flush
  that makes the commit record durable and flushed again when it is rewritten, so after a power cut it is the checksum of *this* file
  or there is none (a fresh baseline is made at the next open) - an old checksum next to a newer, good file of the same size and
  modification second would be called "damaged" (the block-level crash test found exactly that on ext4: 20 of 222 simulated power cuts).
- **A backup of the file as it was before the first commit of an editing session** is kept as `<file>.bak` (copied completely and
  forced to disk before it replaces the previous one; never replaced by a copy that fails the check). If a file that failed its
  checksum is opened anyway and saved, a second copy of the good backup is kept as `<file>.bak.good`, because the next session would
  otherwise copy the damaged data over `.bak`. *Restore Backup* prefers that copy and keeps the damaged file as `<file>.damaged`
  (`.damaged.1`, ... - an earlier one is never overwritten).
- **A folder that takes no new files** (read-only) means no lock, no record and no backup: saving still works, and the window says
  so when the database is opened.
- Cost (measured): the CRC of 100 MB takes 0.15 s on every commit, the backup copy 0.35 s once per editing session - a 29 MB database
  adds about 40 ms per commit. The backup needs as much free disk space as the database.
- Not covered: files larger than 512 MB (no checksum or backup - the limit is `store::sumLimit`), damage that happens
  *before* the first baseline, damage that keeps size and time and is also in `.sum` itself.

**Files over 2 GiB - the Metakit inside the programs can hold them.** Stock Metakit keeps a file's size in one signed 32-bit word, so a
database file cannot pass 2 GiB. The programs released here are built with the author's fork,
[atyr647/metakit](https://github.com/atyr647/metakit) (branch `ccr-7001915e-qdjw33`), which uses 64-bit file positions: below 2 GiB its
files are byte for byte the stock ones; past 2 GiB it writes "wide" tails and flags the header. **The fork is bundled, not downloaded:** an
exact copy of the checked-out source is kept in `tools/vendor/` (`METAKIT-FORK` names the repository, branch and commit and holds the SHA-256 of the
archive; `tools/sync-metakit-fork.sh` moves it to another commit), and `tools/build-kit.sh` compiles it into the runtime of every platform
instead of the Metakit that KitCreator brings (`METAKIT=stock tools/build-kit.sh` builds the old way). `mkstudio --info FILE` says which one a
program has (`metakit 2.4.9.7 (files over 2 GiB: yes)`). A stock Metakit shown a wide file sees an **empty** database (and a commit would hide the
data), so MK Studio still **refuses** a wide file when its own Metakit cannot read one (nothing is touched; the read-only and the editing open alike):
that is what an older program, or one run on another Metakit, does. `store.tcl` probes the loaded library with a small wide file it builds
itself and understands the wide frame in the repair of an interrupted commit.

*The column limit.* The file can be larger than 2 GiB; what is still limited to 2^31-1 bytes is the one **shared column** in which Metakit keeps the
values of a text or blob property. Read from Metakit's source and checked on a real database: each commit moves every value of more than 10,000 bytes (in tables of
very many rows, smaller ones too) out into a column of its own, so a blob column can hold many times 2 GiB as long as it is saved now and then - the tests put
2.1 GiB into one. What the shared column does hold is everything written *since the last commit* plus the committed small values; an edit that would pass the
limit is refused with a message that says to save (`STORE COLUMNFULL`), before anything is changed, and Metakit's own refusal (the fork since `2e2e482` raises an error
where it used to end the program) is turned into the same message: the program then keeps the mark that the changes can only be rolled back, and refuses to save
(`STORE TAINTED`) until **Roll Back**. Verified in CI on every push, on **Linux, Windows and both Macs, with the starpack's own runtime**: every suite, and a real database of
2.9 GiB through `store.tcl` - 30 commits of 100 MiB of blobs crossing 2 GiB, every value read back, a new process opening it, one blob column taken past 2 GiB, 2 GiB of
unsaved values in one column refused and Metakit's real refusal turned into the same message, processes killed in 6 commits and in 5 commits that cross 2 GiB (each file holds
one commit or the other, and later commits work: `tests/test_widebig.tcl`) - plus, every Monday (`metakit-fork.yml`), the fork's own tests (23,636 checks, including crashes after every
single write, a fuzz of random changes against a model, and damaged datafiles) at the fork's newest commit, and the block-level crash test on a real file system. One workaround lives in this repository: the
fork's `tcl/mk4tcl.cpp` gives `Mk4tcl_Init` C++ linkage under KitCreator, and `build-kit.sh` makes it `extern "C"`; the fix itself is on the fork's branch
`mkstudio-c-linkage` (commit `e678a21`), and the workaround goes when that is in the branch the copy is taken from.

**Limits - please read.** The result is "the last confirmed commit, or the one before it, never a mixture", *given* the
model: pages reach the disk in any order, an 8-byte write is atomic (it lies in one sector), and `sync` really forces data
out. It does not cover a disk that lies about having written (some cheap SSDs and USB sticks), a filesystem that loses a
whole file, or data lost from a commit that was already confirmed - and Windows has no `sync` command, so there the
flush is `FlushFileBuffers` (native, or through PowerShell as the fallback) and is only as good as that. A commit that was in flight when the power
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
- a process that started after the lock file was written (a reused pid) is not its owner (Linux, macOS and Windows); a zombie is
  not running; a lock that is not a plain file, or cannot be read, counts as held;
- the lock is named after the file's *real* path (symbolic links resolved), so two names of one database share one lock;
- a process only ever removes *its own* lock; for a lock that is dead but looks held (another computer's name, a recycled pid) the
  "Database in use" dialog offers *Remove Lock...* after a confirmation;
- just before a commit writes, the program checks that the lock file still holds its own text, and refuses to save if somebody else's
  is there (`docs/CONCURRENCY.md` has the measurements that made this necessary).

`tests/test_lock_protocol.tcl` checks this against hand-written independent implementations of the protocol and races six
real processes for a free lock and for the same stale lock - half of them mkit-sql's own implementation when
`MKITSQL_DIR` is set. `tests/test_lock_crash.tcl` kills a process at every step of acquiring, taking over and releasing,
then runs a chaos loop (eight processes, random SIGKILLs, mutual exclusion checked from inside: 0 violations in ~400
acquisitions per run). Between them they found three real defects, all fixed: several processes could each "take over"
the same stale lock; a process whose stale lock was deleted by a competitor at the wrong instant carried on *without any
lock* (this one was in mkit-sql too and is fixed there since 0.4.0 - see [`docs/mkit-sql-integration.md`](docs/mkit-sql-integration.md)); and a zombie (killed, not yet collected) counted as a live owner. mkit-sql implements the same published protocol;
an attempt of mine to change it unilaterally (`670fc86`) was caught by the interop job and reverted.

The lock only protects cooperating programs - others that open the file ignore it - and relies on `O_EXCL`, which is
reliable on local file systems and modern NFS. Read-only folders skip the lock. Derived data (sorted orders, column
copies, lazy results) is guarded by a per-database *generation* that every change and every Roll Back advances.

## Performance and limits (500,000 rows, 29 MB, Linux)

Measured with `tests/bench.tcl` on one shared Linux VM, Tcl 8.6.3, real Metakit, both engines in the same session, one run each
(treat differences under ~30% as noise; the absolute figures move by a factor of two between runs on shared hardware). The first
column is the default engine, **mkit-sql**; the second is the built-in dialect (`MKS_ENGINE=mkql`), which has its own streaming
and caching layer. Neither engine is faster at everything.

| operation | mkit-sql (default) | built-in dialect |
|---|---|---|
| open file, list views / layout (the store; same for both) | ~75 ms | ~80 ms |
| `SELECT ... LIMIT 100` | ~30 ms | ~15 ms |
| `WHERE` on `=`, ranges, `IN`, `BETWEEN` (pushed into Metakit), 6,658 rows out | 0.17-0.19 s | 0.18-0.22 s |
| `WHERE name LIKE 'person 4999%'` | **~0.1 s** (prefix decided inside Metakit) | ~1.7 s (full scan) |
| `SELECT COUNT(*)` | ~1 ms | ~1 ms |
| `COUNT(*)` with two conditions | ~0.27 s | ~0.28 s |
| `SUM / MIN / MAX` over everything | ~3.9 s | ~3.1 s |
| `GROUP BY` 50 groups | ~3.7 s | ~2.9 s |
| `ORDER BY <number> DESC LIMIT 50` | ~4.1 s every time | ~0.9 s first time, **~0.3 s** after (cached column) |
| `ORDER BY <text> LIMIT 50` | ~4.2 s | ~4.0 s |
| `SELECT *` over all 500,000 rows | ~1.7 s, **first 100,000 rows only** (the window says so) | **~0.16 s, all rows, streamed** |
| `SELECT ... ORDER BY <number>` over all rows | ~8-10 s, first 100,000 rows only | ~2.3 s first time, ~1.2 s after, all rows, streamed |
| `UPDATE` 10,000 scattered rows of a string column | ~9 s | ~10.6 s |
| `UPDATE` 10,000 contiguous rows | ~17.7 s | ~23.9 s (this VM was slower during this part; the same statement took ~9 s in earlier runs) |
| `DELETE` 10,000 scattered rows | **~29 s** | ~13.8 s |
| open a view in the editor / jump to any row (the grid; same for both) | ~0.1 s / ~4 ms | |
| click a column header in the editor (sorts all 500,000 rows) | ~1.5 s first time, instant after (cached) | |
| select all + copy 500,000 rows (34 MB) | ~10 s | |

What this means: mkit-sql is the richer language and answers prefix `LIKE` far faster; the built-in dialect is faster for big sorts,
repeated `ORDER BY ... LIMIT`, and results too large for memory (it hands the grid a streaming source), and quicker at scattered
`DELETE`. If you work with half-million-row views and mostly browse and sort, `MKS_ENGINE=mkql` is the better tool today; if you
need joins, CTEs, windows and standard syntax, mkit-sql is the only one that has them. Metakit's own limits (below) apply to both.

Mutations are still the slowest thing here, and the limit is **Metakit's design**: columns are stored contiguously,
so rewriting a variable-length value or deleting a row shifts everything after it (2-4 ms each on 500,000 rows,
growing with the data behind the row), while appending costs ~3 us per row. Past about a thousand changes the
store therefore rebuilds the affected tail of the view instead - append the changed copy after the last row, then
remove the old tail with one ranged delete - for a 2.5-3x gain; the cost becomes proportional to the rows from the first
change to the end of the view, not to the number of changes. Changes that touch only fixed-width columns (numbers) were
never slow, and a run of consecutive deletes is one call. If the copy fails the view is cut back to its old size, so
nothing is half-changed. The app keeps the UI responsive, skips writes that change nothing, and Roll Back
undoes a whole run (and is fast). Going much beyond this needs a different storage layout, not a smarter loop.

(An earlier version of this section compared the two engines' bulk `UPDATE` / `DELETE` rebuilds at an older mkit-sql; the table
above supersedes it. `tests/bench_mutation.tcl` still runs identical statements on identical files through both and compares the
resulting tables row by row in CI.)

How the built-in dialect's speed-ups work, and their limits (the grid and the store parts apply to both engines):

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
- **These optimisations belong to the built-in dialect (`MKS_ENGINE=mkql`).** mkit-sql has its own planner, pushdown and
  spilling (see its README for its measured scale); an engine of your own designs its own speed; `store.tcl` offers `select`, `fetch`, `fetchAt`, `column` and the cache for exactly that, and the
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
mkstudio.vfs/lib/mkitsql/            mkit-sql, the SQL engine (vendored; SOURCE names the commit; tools/sync-mkitsql.sh)
mkstudio.vfs/lib/kitfmt/             kitfmt, Ribbon's reference reader for .kit files (vendored from atyr647/ribbon kit/kitfmt;
                                     SOURCE names the commit; tools/sync-kitfmt.sh, which also copies its golden kits to tests/kits)
mkstudio.vfs/lib/app-mkstudio/
    store.tcl     the ONLY file that calls mk::*  (incl. the advisory write lock)
    engine.tcl    the query-language seam (documented contract)
    mkql.tcl      the built-in dialect (stand-in and test reference; MKS_ENGINE=mkql): parser, binder, value semantics
    mkplan.tcl    its fast execution path: pushdown, compiled expressions, streaming aggregates, lazy results
    version.tcl   the version number (one place) and semantic-version comparison
    update.tcl    update check, checksum-verified download, self-replacement (no Tk)
    crash.tcl     error handler, crash reports, unexpected-end detection
    kit.tcl       the Kit tab (on kitfmt); kitverify.tcl  the separate process it verifies in (mkstudio --kitverify KIT)
    theme icons menus widgets grid editor explorer docs app
packaging/     NSIS installer, .deb/.tar.gz, macOS .app/.dmg, icons (tools/make-icons.py draws them)
tests/         the suites above; tools/  runtime build (build-kit.sh, fetch-runtimes.sh), wrap.tcl, sync-mkitsql.sh, make-icons.py
build.sh  .github/workflows/build.yml   (build, test and release; a manual "lock soak" job; the release job publishes a tag only when everything is green)
RELEASE_NOTES.md       the text of the current release
docs/CONCURRENCY.md    the shared write-lock / generation policy (for mkit-sql or a server), with its measurements
docs/mkit-sql-integration.md   how mkit-sql is wired in, what was found, what differs
docs/QA-CHECKLIST.md   the manual checks automation cannot do
docs/OPEN-ITEMS.md     what is still open, the evidence, and whether it is worth doing
docs/screenshots/      what the program looks like
```
