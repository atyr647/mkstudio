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
- **Files over 2 GiB are refused, not shown as empty.** The Metakit fork with 64-bit file positions
  ([atyr647/metakit](https://github.com/atyr647/metakit)) writes "wide" files past 2 GiB; stock Metakit, which these programs contain, sees such a file
  as an empty database - and a save would hide the data. The program now recognises a wide file, says so and touches nothing; it is also ready for the
  fork (reads, edits, repairs an interrupted commit on a wide file, refuses the one edit the fork cannot survive - a single column past 2 GiB). The fork
  is tested against MK Studio in CI every week, up to a real 2.9 GiB database; building the released programs with it is not decided (a kit with the fork inside does not build yet).
- mkit-sql 0.4.1 (the lock fix, an unreadable lock counts as held, its Windows flush now runs, a licence file).

### Also new in rc.2 (since rc.1)

- **Standard SQL.** The query window now runs [mkit-sql](https://github.com/atyr647/mkit-sql) 0.4.1: joins, CTEs including
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
  to an open database, a process frozen for many seconds at exactly the wrong moment). On macOS-Intel the lock stress test
  twice saw two processes inside at once under deliberately extreme load; the cause is not established.
- Power safety is tested with simulated power cuts and real kills, never with a real power cut (`docs/QA-CHECKLIST.md` has the
  manual test). A disk that lies about having written data cannot be helped.
- Lock stress on CI runners (eight processes, random kills): no overlap in ~58,000 acquisitions on Linux and Apple silicon; on the
  Intel Mac runner three in ~12,000 (details and the commit-time check that limits the damage: `docs/CONCURRENCY.md`).
- The programs are not signed or notarized (see above). Nobody has used this release for months yet.
- mkit-sql's own repository still has the three open items listed in `docs/mkit-sql-integration.md` (a patch is provided); this
  release does not depend on them.
