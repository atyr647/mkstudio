## MK Studio 1.0.0-rc.3 - release candidate

A workbench for Metakit databases: browse, query (SQL-like), design and edit, as one self-contained program.
This is a **release candidate**: everything below is tested, but it has not yet had months of use by other people.
Please try it on copies of databases you care about and report what you find. `docs/QA-CHECKLIST.md` lists the hour of manual
checks (real power loss, first run on each system) that automation cannot do.

### What changed since 1.0.0-rc.2

- **The lock can no longer be taken away from a live program by a takeover race.** After a crash the next program takes over the
  dead one's lock file; two programs doing that at the same moment could (under a rare timing, reproduced on demand) end up with the
  second one deleting the first one's brand-new lock, and both believing they owned the database. A takeover now looks at the old lock
  without moving it, moves only one it has judged stale (after checking the name still names the file it judged), and puts back a live
  one at once - and a program re-reads its lock after writing it. The program that is overtaken because it was frozen at the wrong moment notices when it wakes up. The check made just
  before every save stays. In a stress test with eight programs, random kills and freezes: 8,425 lock acquisitions, no overlap.
  The same fix is in mkit-sql 0.4.1.
- **Saves reach the disk through a small native library instead of starting programs.** On Windows each save used to start PowerShell
  three times (0.4-0.7 s each, hidden, with an encoded command - which also looks like malware to some virus scanners); now it is one
  call, milliseconds. On macOS it is `F_FULLFSYNC`, which also empties the drive's own write cache (`sync` could not). On Linux it is
  `fsync` on the file and its folder. The library is compiled in CI for each system and carried inside the program; where it cannot be
  loaded the program does what it did before. `mkstudio --info FILE` says which one is in use.
- **Tested against a real file system's write ordering - and it found something.** A new CI test puts ext4, xfs and btrfs on a device
  that logs every write in the order the disk completes them, makes real commits with MK Studio on it, replays the log onto a copy of
  the disk and "cuts the power" after every single write (318, 96 and 265 different disk states): each one is mounted, the database is
  opened, and it must hold exactly one of the commits - never older than the last one acknowledged, never reported damaged. All pass.
  The first run found that on ext4, after some power cuts, an old checksum file could sit beside the new, good database and the program
  would call it "damaged" (nothing was lost, but it offers a restore); the checksum is now removed when a save begins and flushed when
  it is rewritten. The same test with the flushes switched off fails as it must. (A model of disk ordering is not the real thing; this
  is the real thing, short of pulling a plug. It does not cover a disk that lies or a write torn inside one sector.)
- **Tcl/Tk 8.6.18** (the last 8.6 release) on all three systems, built from checked sources with KitCreator kept in the repository -
  the macOS build used to take KitCreator's moving "trunk" unchecked.
- **Databases over 2 GiB.** The programs now contain the Metakit fork with 64-bit file positions
  ([atyr647/metakit](https://github.com/atyr647/metakit), an exact copy is kept in `tools/vendor/` and compiled into the Linux, Windows and macOS
  runtimes): a file is no longer limited to 2 GiB. Below 2 GiB the files are byte for byte the ones stock Metakit writes. CI creates a real
  2.9 GiB database on each system through MK Studio (commits crossing 2 GiB, every value read back, processes killed mid-commit). A "wide" file (past 2 GiB)
  opened by a program with a stock Metakit - an older MK Studio, another tool - would look empty and a save would hide the data; this version recognises
  such a file when its own Metakit cannot read it, says so and touches nothing. `mkstudio --info FILE` tells which Metakit a program has.
- **What is still limited, and what is not.** A blob or text column can hold far more than 2 GiB - Metakit moves every value of more than 10,000 bytes out of the
  shared column when the database is saved (a real test puts 2.1 GiB into one column). The shared column itself, which holds what was written since the last
  save plus the small values, is limited to 2^31-1 bytes: an edit that would pass it is refused with a message that says to save, nothing is changed, and if Metakit
  refuses an edit first (the fork now raises an error instead of ending the program) the database can only be rolled back - the program says so and offers **Roll Back**.
  This also corrects the first version of the guard, which counted all the values of a column and refused at 2 GiB.
- **The Metakit fork's own fixes since** (all in the bundled copy): size errors that can be recovered from, two Mk4tcl bugs (a property type kept for a view that
  was gone; `mk::file aside` not detaching views), damaged datafiles no longer crash it (checked as they are read), more than one interrupted commit in the same file.
- mkit-sql 0.4.2 (the lock fix, an unreadable lock counts as held, its Windows flush now runs, a licence file, the corrected column guard).

### Also new in rc.2 (since rc.1)

- **Standard SQL.** The query window now runs [mkit-sql](https://github.com/atyr647/mkit-sql) 0.4.2: joins, CTEs including
  `WITH RECURSIVE`, window functions, `MERGE`, `LATERAL`, `ROLLUP`/`CUBE`, dates and intervals, `EXPLAIN`, and bounded memory for big
  results. It runs on MK Studio's own storage layer, so a statement's change is saved, rolled back, locked and checksummed like any
  edit; the old built-in dialect stays available for the tests (`MKS_ENGINE=mkql`). The engine is part of the program (not
  downloaded), at a recorded commit that CI checks byte for byte, and mkit-sql's own storage suites run against this program's
  storage code on every build.
- **A commit checks its lock first.** If another program has replaced this program's lock file since the database was opened, the
  save is refused (the changes stay in the open database) instead of two programs saving into one file.
- **Windows: the disk flush now really runs.** In rc.1 the program asked PowerShell to force each save to disk, but PowerShell
  started straight from a Windows GUI program does nothing at all - no error, no effect - so on Windows saves were *not* forced
  to disk. They are now (PowerShell is started through `cmd /c`; a test proves that a script really executes).
- **A finished save can no longer be undone.** The "undo the unfinished save" record is rewritten to describe the finished file
  before it is deleted, so a record that cannot be deleted (a virus scanner on Windows) or whose deletion is lost in a power
  cut can no longer roll back a save you were told succeeded - or empty a brand-new database.
- **One lock per real file.** Opening a database through a symbolic link and directly now takes the same lock; a lock file that
  cannot be read counts as held; after a crash or restart a lock whose process id was reused by another program is recognised
  on Windows and macOS too; *Remove Lock...* in the "Database in use" dialog (with a confirmation) clears a lock you know is dead.
- **A damaged file's good backup survives** being opened anyway and saved; *Restore Backup* never overwrites an earlier
  `.damaged` file; backups are complete and on disk before they replace the previous one.
- **Updater hardening**: private scratch folder (no predictable name in a shared temp folder); on Windows only the system's own
  `curl`, `certutil` and PowerShell are used (never one planted next to the program); on Linux and macOS the new version replaces
  the program in one rename (no instant without a program); a package-managed copy (`/usr/bin/mkstudio`) is never replaced;
  the Windows helper handles folders with spaces, parentheses and accented letters, waits as long as needed and retries; a
  GitHub rate-limit answer is explained.
- **Crash reports**: a user name with `(`, `[` or `*` in it no longer breaks the report; many "unexpected end" reports can no
  longer push out the real crash report; quoted text in error messages (where a value could slip in) and any file path are
  removed.
- **Current runtimes everywhere**: Windows and Linux programs now run on Tcl/Tk 8.6.18 with zlib 1.3.1 (they were on the 2014
  Tcl/Tk 8.6.3 with zlib 1.2.8); the Linux program needs glibc 2.28 or newer.
- **The update check is tested against the real GitHub release** on Linux, macOS and Windows in CI: real API, real download,
  real checksum, the real published program started with `--selftest`.
- **Databases in read-only folders** (no lock, no backup possible) say so when opened.

### Downloads

| System | File | Notes |
|---|---|---|
| Windows 10/11 (64-bit) | `MKStudio-<version>-windows-x64-setup.exe` | per-user installer, no administrator rights; or the single file `mkstudio-windows-x86_64.exe` |
| macOS (Apple silicon) | `MKStudio-<version>-macos-arm64.dmg` | drag to Applications |
| macOS (Intel) | `MKStudio-<version>-macos-x86_64.dmg` | drag to Applications |
| Linux (x86-64) | `mkstudio_<version>_amd64.deb` (GitHub shows the `~` of the version as a dot), `MKStudio-<version>-linux-x86_64.tar.gz` | tarball installs to `~/.local` without root |
| any | `mkstudio-<platform>` | the bare program (what "Check for Updates" replaces itself with) |

`SHA256SUMS` lists the checksum of every file.

### These files are not signed

There is no code-signing certificate behind them. In practice:

- **Windows** SmartScreen shows "Windows protected your PC" - choose *More info > Run anyway*.
- **macOS** the program carries only the ad-hoc signature its Tcl runtime was built with (`codesign` refuses to sign a
  starpack again, and the app bundle is not sealed); the first time, on macOS 15 and later: try to open it, then *System Settings > Privacy & Security >
  Open Anyway*; on macOS 14 and earlier: right-click the app > *Open*. What "not sealed" costs is listed in the README.
- **Linux** nothing to confirm.
- The checksums catch a damaged download, **not** a malicious one: if someone took over the project's GitHub account they could
  publish matching checksums. Download from the project's own releases page only.

### Safety of your data

- Nothing is written to a database until you commit; an interrupted commit (program killed, power cut) is undone the next time
  the file is opened, so the file is the state before that commit.
- Each commit is forced to disk (`sync` on Linux and macOS, `FlushFileBuffers` through PowerShell on Windows), a checksum of the
  finished file is kept next to it (`.sum`) and a copy of the file from before an editing session (`.bak`). A file that no
  longer matches its checksum is reported when it is opened, with the option to restore the backup.
- What this cannot do: a disk or SSD that lies about having written data, files over 512 MB (no checksum or backup), and anything
  Metakit itself gets wrong. Tested with simulated power cuts and real kills - not with real power cuts. Keep your own backups.

### Updates and crash reports

- *Help > Check for Updates* asks GitHub for the newest release (one request; only the program name and version are sent). It
  can replace the program itself after checking the download's SHA-256 against `SHA256SUMS` and starting the new one once as a
  test; the previous version stays next to it as `.old`. Installed copies (`.deb`, `.app`) are updated by downloading the new
  installer. Turn the automatic daily check off under the same menu.
- If the program hits a bug it saves a report (version, system, error, call stack as procedure names, the last things it did)
  to a local folder (*Help > Open Crash Reports Folder*). It contains no SQL and no data. Nothing is sent unless you press
  *Report on GitHub* and submit it yourself. A crash the program cannot catch is noticed at the next start.

### Known limits

- Metakit is unmaintained and has no checksums of its own; MK Studio adds them (and a backup) for files up to 512 MB.
- **mkit-sql is not faster at everything.** A query result is limited to 100,000 rows in memory (the window says when it was cut);
  on a 500,000-row table `ORDER BY ... LIMIT 50` takes about 4 s and scattered `DELETE`s are about twice as slow as with the old
  built-in dialect, which streams results of any size and caches sorts. `MKS_ENGINE=mkql` starts the program with that dialect;
  the README has the measured table.
- Concurrent writers are kept apart by an advisory lock only (`docs/CONCURRENCY.md` lists what that does not cover: a hard link
  to an open database, a process frozen for many seconds at exactly the wrong moment).
- Power safety is tested with simulated power cuts and real kills, never with a real power cut (`docs/QA-CHECKLIST.md` has the
  manual test). A disk that lies about having written data cannot be helped.
- Lock stress on CI runners (eight processes, random kills): rc.2 saw three overlaps in ~12,000 acquisitions on the Intel Mac runner; they were
  the takeover race fixed in this release, which a test now reproduces on demand, and the stress runs since show none (`docs/CONCURRENCY.md` has the details
  and the commit-time check that limits the damage if one ever happens).
- Databases over 2 GiB are tested with a 2.9 GiB database on each system, not with terabytes, and the Metakit that holds them is a one-person fork of an
  unmaintained library: the bundled copy is pinned and checked, and a weekly CI run tests the fork's newest commit against this program.
- The programs are not signed or notarized (see above). Nobody has used this release for months yet.
- mkit-sql's open items are closed: what used to be a patch is in mkit-sql itself (0.4.2), and this program carries that exact copy.
