# Concurrency policy for Metakit databases

One policy, shared by **every component that touches a database file**: MK Studio, the SQL engine
(mkit-sql), a database server, scripts. The rules are small on purpose, so another program in another
repository can follow them without sharing any code - `tests/test_lock_protocol.tcl` checks the
protocol against hand-written, independent implementations of it.

## Why a policy is needed

Metakit has **no locking of its own**. Measured (`tests/test_crash_safety.tcl`):

- a process that opens the file *while another commits* sometimes sees a half-written or unreadable
  state (between under 1% and 12% of reads in the probe, depending on timing);
- two writers can overwrite each other's commits.

A killed process never leaves a torn file (also measured), but concurrent access is not safe by itself.

## The rules

1. **One writer per file.** A component that opens a database for writing owns it until it closes it.
2. **A writer takes the lock first** (protocol below). If the lock is held by someone else it does *not*
   write; it may open read-only, with a warning that what it sees can be inconsistent during the owner's commits.
3. **Readers take no lock** but must tolerate a failed or odd read while a writer commits (retry or
   report), and must not cache derived data across changes (rule 6).
4. **Nothing is written until commit.** Files are opened `-nocommit`; a writer that exits without
   committing leaves the file as it was. Commits are the only moments readers can be hurt.
5. **A server owns its database exclusively** for as long as it runs: it holds the lock for its whole
   lifetime and announces itself in it (`role` / `endpoint`, below). Clients (including MK Studio) talk
   to the server instead of opening the file; if they open the file anyway they are told who owns it and
   get read-only access at most.
6. **Derived data is keyed by generation, and generations never repeat.** Anything computed from a database (sorted orders, column copies,
   query results that read live data) is valid only for the generation it was built from
   (`::store::generation`, bumped by every change and by Roll Back). A component that caches must check it;
   a streaming result must report itself `stale` once the generation moves (see the `provider` contract in
   `engine.tcl`). The engine freezes its own live results before it changes data, and a database being closed freezes
   them too; a result that is too big to freeze simply stays stale for good - closing and reopening the same file can
   never bring it back to life, because a generation is never reused.
7. **One process, one door.** Inside a process, only `store.tcl` calls `mk::*`, so the rules are enforced
   in one place. An engine that opens files itself must call `::store::openFile` (or implement the protocol).

## The lock protocol

The lock is a file next to the database: `<database>.lock` (for `sales.mk`, `sales.mk.lock`). MK Studio and
mkit-sql implement it independently and are tested against each other (`tests/test_lock_protocol.tcl` with
`MKITSQL_DIR` set races processes of both implementations). **This text is the protocol; change it only together with
every implementation** (an earlier revision of MK Studio changed the line format and the mutex name on its own while
mkit-sql was adopting the published ones - reverted; see `docs/mkit-sql-integration.md`).

**Content** - one line of text, space separated:

    <pid> <host> [<role> [<endpoint>]]

| field | meaning |
|---|---|
| `pid` | process id of the owner (decimal) |
| `host` | name of the machine the owner runs on (`info hostname`) |
| `role` | optional: what the owner is, e.g. `server`; `-` means none (when only `endpoint` follows) |
| `endpoint` | optional: where to reach it, e.g. `tcp://db.example:5433` |

Readers must ignore fields they don't know.

**Acquire** (a writer, before opening the database for writing):

1. Create `<database>.lock` with *exclusive create* (`O_CREAT|O_EXCL`; Tcl: `open $f {WRONLY CREAT EXCL}`) and
   write the line above. If that succeeds you own the database.
2. If the create failed, look at why:
   - **no file exists any more** - a competitor deleted the stale lock between your create and your look. **Retry.**
     Only a folder that will not let you create files at all (read-only, no permission) means "carry on without a
     lock". (Treating a vanished file as "read-only folder" lets two processes both think they own the database. It was
     found by `tests/test_lock_protocol.tcl` in MK Studio and is also in mkit-sql - patch:
     fixed in MK Studio and, since 0.4.0, in mkit-sql.)
   - **the file exists** - read and classify it:
     - **held** - another live process owns it, or it names another *host* (liveness of a remote process can't be
       checked, so it is always respected). Do not write. Report `pid host role endpoint` to the user.
     - **stale** - same host and the pid is not running (a *zombie* - killed but not yet collected by its parent - is
       not running); or the pid runs but started after the lock file was written (Linux: pid reused); or the file is
       empty or garbled and older than **5 seconds** (its creator died between creating and writing it).
     - **ours** - same pid and host (left by an earlier run of this very process).
3. **Take over** a stale/ours lock under the guard file `<database>.lock.guard`, so that processes that all see the
   same stale lock cannot each delete the winner's fresh one:
   1. create the guard exclusively; if it exists, wait (~40 ms) and try again for about two seconds; a guard older
      than **10 seconds** was abandoned by a crash and is deleted;
   2. with the guard held, **classify the lock again**; only if it is still stale/ours (or gone) delete it (an
      implementation may create the new lock before or after releasing the guard);
   3. delete the guard. Exactly one process wins; the others find a live owner. A process that cannot get the lock
      after waiting reports "starting at the same moment, please repeat".

**Release** (on close): delete `<database>.lock` *only if it still holds exactly what you wrote*. If it was replaced,
leave it alone.

**Read-only open** takes no lock. A read-only opener may look at the lock to warn the user.

**One name per database.** The lock file is named after the database's *real* path: MK Studio resolves symbolic links (the last
component too) before it takes the lock, so `current.mk` (a link) and `real/sales.mk` share one lock. A *hard link* is a second name
for the same file and cannot be told from another file by name: inside one MK Studio process the same device and inode is refused
("already open"), but a different process opening a hard link of a database that is open elsewhere takes a different lock file.
Do not hard-link databases.

**Conformance - what both implementations do, and the differences left** (MK Studio's `store.tcl` and mkit-sql 0.4.0's `db.tcl`): the line format, the guard name and the 5 s / 10 s limits are identical and tested against each other (`tests/test_lock_protocol.tcl`); both resolve symbolic links before naming the lock, both refuse to follow or read a lock that is not a plain file (it counts as held), both re-check the lock inside the guard, both treat a pid that started after the lock file was written as not its owner (MK Studio on Linux, macOS and Windows; mkit-sql on Linux only - stricter systems never take a lock away, so this only makes mkit-sql keep a dead process's lock until it is removed by hand). One difference is a defect of mkit-sql 0.4.0: a lock file that exists but cannot be *read* counts there as free (MK Studio: held); `docs/mkit-sql-protocol-sync.patch` fixes it.

**An unreadable lock is a held lock.** If `<database>.lock` exists but cannot be read (another user's file under a strict umask, a
permissions problem) the database is treated as held by an owner that cannot be named - never as free.

**Process start times, on every system.** A lock names a pid; after a crash or a restart the system may hand that pid to an
unrelated program, which would make the lock look held for ever. The process that *wrote* the lock is told from a later one with
the same pid by its start time: a process that started after the lock file was written cannot be its owner (Linux `/proc`; macOS
and BSD `ps -o etime=`; Windows PowerShell `Get-Process`). Where nothing can tell, the lock is respected. The application also
offers *Remove Lock...* (with a confirmation) for a lock the user knows is dead - for example a lock from another host name, which
is always respected because a remote process cannot be checked.

**Limits.** The lock is advisory: programs that don't follow it are not stopped. `O_EXCL` is reliable on local
file systems and modern NFS; on exotic network file systems it may not be, in which case run one server instead.
**Time limits and slow processes.** The two abandonment limits (5 s for an empty lock file, 10 s for the takeover guard) assume that a
live process is never held up for that long at those two points - between creating the lock file and writing its pid into it,
and while it holds the guard (judging a lock stale and deleting it, which includes asking the system whether a pid is alive).
A process that *is* held up that long (starved on an overloaded machine, suspended, swapped out) is treated as dead and overtaken,
and when it wakes up both believe they own the database. `tests/test_lock_crash.tcl` reproduces both cases on demand (a process
stalled at exactly those points: limit shortened to 1 s -> overlap; the real limits -> no overlap). The chaos test runs with the
limits shortened to 1 s, so on a very slow runner it can see this; processes whose acquisition took more than half the shortened
limit are reported as SLOW and overlaps they take part in are counted as excused, not failed (set `MKS_CHAOS_STRICT=1` to see
them all). **Measured on CI runners** (`tests/soak_lock_chaos.tcl`, the manual "lock soak" job: eight processes take the lock in a loop while
random ones are SIGKILLed, and in one setting also frozen for 1.3 s; two processes inside at once is a violation):

| runner | limits | acquisitions | violations |
|---|---|---|---|
| Linux | shortened (1 s), real (5 s / 10 s), real + freezes | 10,519 / 20,902 / 16,589 | 0 / 0 / 0 |
| macOS arm64 | the same three | 2,475 / 3,850 / 3,189 | 0 / 0 / 0 |
| macOS Intel | shortened | 3,528 | 0 |
| macOS Intel | real | 6,952 | **1** |
| macOS Intel | real + freezes | 5,702 | **2** |

So on Linux and Apple silicon no overlap was seen in ~58,000 acquisitions; on the Intel macOS runner (the slowest machine in the
set: acquisitions there took up to 6 s) three overlaps in ~12,000. In every logged case another process had *taken over the lock
of a process that was alive and inside* (two or three takeovers within ~300 ms; the victim then found its marker file empty or
gone). What is established: it needs real contention (eight processes, kills every 120 ms) and a loaded machine, and it is not the
pid-liveness probe (`killProbe` and `pidAlive` were hardened before and the overlaps still occur). **A reading that fits the logs,
not proven:** when a process is killed while it holds the takeover guard, the abandoned guard is removed once it is 10 s old by
every waiter that notices at about the same time - and a waiter that checked the age of the *old* guard can delete, by name, the
*fresh* guard that another waiter has just created, so two of them are inside the takeover section together, and the second one
deletes the first one's brand-new lock. (Both implementations delete by name; the protocol cannot be made identity-safe without
changing the guard's content or name, which must be done in both implementations together.)

**What MK Studio does about it:** just before a commit writes, it checks that the lock file still holds its own text
(`store::verifyLock`). If somebody else's text is there the commit is refused with the error code `{STORE LOCKLOST text}` - the
changes stay in the open database - and a lock file that has vanished is taken again, exclusively. Of two processes that overlapped
through a replaced lock, the one whose lock was overwritten therefore cannot save. This narrows the harm to a few microseconds
between that check and Metakit's write; it does not make the lock a guarantee. **Treat the lock as protection against accidents
(two windows, two programs), not as a guarantee against a hostile or badly overloaded machine.**

Raising the real limits makes the window rarer, never zero; closing it needs a lock the operating system itself
releases when the process dies (`flock`/`LockFileEx`), which Tcl cannot do from a plain file channel.

A crashed owner leaves its lock behind until the next opener finds it stale (same host) - there is no timeout for
remote owners, by design. The only time-based rules are the two abandonment limits above (5 s, 10 s), compared with the
local file system clock.

## Files next to a database

MK Studio keeps a few small files beside `sales.mk`. Another component that writes the same database should know them:

| file | what | lifetime |
|---|---|---|
| `sales.mk.lock`, `.lock.guard` | the advisory write lock (above) | while a writer has the file open |
| `sales.mk.commit` | `<header-hex16> <size>` of the last committed state, or `empty 0` for a new file - written and forced to disk **before** a commit; after it, first rewritten to describe the *finished* file (so it cannot undo the commit even if deleting it fails or the delete is lost in a power cut), then removed | only during a commit; finding it at open means the commit never finished, and the next writer puts the header and size back (`store::repairFile`). Do not delete it, do not "complete" the commit |
| `sales.mk.sum` | `<crc32> <size> <mtime>` of the file after its last commit | kept; checked at the next write-open only while size and mtime still match |
| `sales.mk.bak` | the file as it was before the first commit of the last editing session (copied completely and forced to disk before it replaces the previous backup) | kept; replaced at the next session that commits |
| `sales.mk.bak.good` | a second copy of the backup, made when a file that failed its checksum was opened anyway and then saved: the next session would otherwise copy the damaged data over `.bak`. Restore Backup prefers it and deletes it afterwards | until restored |
| `sales.mk.damaged` (`.damaged.1`, ...) | a file that failed its checksum, set aside by *Restore Backup* - an earlier one is never overwritten | until the user deletes it |

A program that writes the database without this protocol (mkit-sql's own storage layer, a script) leaves `.sum` out of date; that is
harmless - the next MK Studio open sees a different size or time, calls it a legitimate change and takes a new baseline.
If such a program commits while a `.commit` record exists, the record describes a state that no longer exists: stop and ask the
user rather than guess. Copying or moving a database: take `.mk` only, with no `.lock`, `.commit`, `.sum` (they would be stale).

## API (`store.tcl`)

    ::store::openFile path ?-readonly? ?-create?   takes/refuses the lock; error code {STORE LOCKED pid host role endpoint}
                                                   (the path is made canonical first: symbolic links resolved)
    ::store::closeFile tag                         releases our lock (only ours)
    ::store::canonical path                        the real path a database and its lock file are named after
    ::store::lockInfo path                         dict: state free|ours|stale|held, pid host role endpoint
                                                   (a lock that is not a plain file, or cannot be read, is "held" by pid 0 / host unknown)
    ::store::breakLock path                        remove a lock the USER says is dead (the application asks first); returns its text
    ::store::verifyLock tag                        is the lock still ours?  commit calls it; error code {STORE LOCKLOST text}
    ::store::unprotectedNote tag                   "" or why this open has no lock / record / backup (a folder that takes no new files)
    ::store::lockedByOther tag                     for a read-only open: who holds the write lock ("" if nobody)
    set ::store::lockRole server                   before openFile: announce a long-lived owner ...
    set ::store::lockEndpoint tcp://host:port      ... and where clients should connect
    ::store::generation tag                        a number that changes on every modification and Roll Back, never repeats
                                                   (one counter for all databases and all reopenings), -1 when not open
    ::store::onClose cmd                           cmd tag is called just BEFORE a database closes (results freeze themselves)
    ::store::cacheConfigure -budget MB             derived-data cache budget (default 256 MB, env MKS_CACHE_MB; 0 = off)
    ::store::cacheStats                            entries bytes budget hits misses evictions
    ::store::integrityState tag                    ok none changed damaged - the checksum verdict at the last write-open
    ::store::restoreBackup path                    put the backup back (the protected <path>.bak.good if there is one, else <path>.bak);
                                                   the damaged file is kept as <path>.damaged, .damaged.1, ... (call with the file closed)

## Checklist for adding mkit-sql or a server

- [ ] opens databases only through `::store::openFile` (or implements the protocol above to the letter)
- [ ] a server sets `lockRole`/`lockEndpoint` before opening, and holds the file for its lifetime
- [ ] any cache of data read from the database is keyed by `::store::generation` (or by its own change counter
      that every write path bumps)
- [ ] results that read live data implement the provider contract and pass `tests/provider_contract.tcl`
- [ ] statements that change data call `::mkql::lzFreezeAll` first (or the equivalent in the new engine)
- [ ] runs `tests/test_lock_protocol.tcl` against its own lock implementation if it has one (replace the child)
- [ ] resolves symbolic links before naming the lock, treats a lock that is not a plain file or cannot be read as held, and checks
      that its lock is still its own just before it writes (see "Conformance" and `store::verifyLock` above)

## Results, caches and lifetimes

- A streaming result (`provider`) is either **live** (reads the database, valid for one generation), **frozen** (holds
  its rows in memory, valid forever) or **stale** (the data moved on; returns no rows and says so). There is no fourth
  state: it can never return rows from a different state than the one the query saw
  (`tests/test_provider_lifecycle.tcl`: edits, appends, deletes, restructuring, other views, Roll Back, close, reopen,
  two databases, destroyed results; `tests/provider_contract.tcl` is the engine-independent version).
- The derived-data cache holds column copies and sort orders for the current generation only, in a byte budget shared by
  all open databases with least-recently-used eviction; closing a database drops its entries.
- Statements are all-or-nothing: a failed or cancelled `UPDATE`, `DELETE` or `INSERT` changes nothing (`tests/test_engine_semantics.tcl`).
  Cancel is honoured while reading, never in the middle of writing.

## What is tested

`tests/test_lock_protocol.tcl`: the lock file format; a lock written by a foreign implementation is respected
(and left untouched), including `role`/`endpoint` in the message and error code; stale, empty-and-old and
abandoned-guard locks are taken over (also reused pids, zombies, and processes of other users); close never removes someone
else's lock; **six processes racing** for a free lock and for the same stale lock - exactly one wins every round (with the
guard removed, or with a vanished lock treated as unlockable, the same test fails). With `MKITSQL_DIR` set, half of the
racers are mkit-sql's implementation. `tests/test_lock_crash.tcl` kills a process at every step of acquiring, taking over
and releasing (created, written, holding the mutex, between delete and create, after release) and then runs a chaos loop:
eight processes take the lock repeatedly while the test SIGKILLs random ones; no two live processes ever hold it at once
and it is never lost. `tests/test_crash_safety.tcl` covers crash recovery of the data and read-only access.
`tests/test_durability.tcl` covers the rest of what is described here: a lock replaced behind a program's back refuses the commit, a vanished
lock is taken again, a foreign lock survives a close, a lock that is a folder or cannot be read is held, symbolic links and hard links to
an open database, `breakLock`, a read-only folder. `tests/soak_lock_chaos.tcl` (the manual "lock soak" CI job) produced the measurements above.
