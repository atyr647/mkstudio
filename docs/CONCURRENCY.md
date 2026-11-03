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
`MKITSQL_DIR` set races processes of both implementations).

**Content** - one line of text, space separated:

    <pid> <host> <start> [<role> [<endpoint>]]

| field | meaning |
|---|---|
| `pid` | process id of the owner (decimal) |
| `host` | name of the machine the owner runs on (`info hostname`) |
| `start` | the owner's process start time token (Linux: field 22 of `/proc/<pid>/stat`) so a *reused* pid is not mistaken for the owner; `-` (or empty) where the system has no such thing |
| `role` | optional: what the owner is, e.g. `server`; `-` means none (when only `endpoint` follows) |
| `endpoint` | optional: where to reach it, e.g. `tcp://db.example:5433` |

Readers must ignore fields they don't know (older writers wrote only `pid host`). Writers on Linux must write a real
`start` token: a reader there compares it with the live process and calls a mismatch "pid reused = stale".

**Acquire** (a writer, before opening the database for writing):

1. Create `<database>.lock` with *exclusive create* (`O_CREAT|O_EXCL`; Tcl: `open $f {WRONLY CREAT EXCL}`) and
   write the line above. If that succeeds you own the database.
2. If the create failed, look at why:
   - **no file exists any more** - a competitor deleted the stale lock between your create and your look. **Retry.**
     Only a folder that will not let you create files at all (read-only, no permission) means "carry on without a
     lock". (Treating a vanished file as "read-only folder" let two processes both think they owned the database;
     found by `tests/test_lock_protocol.tcl`, and present in mkit-sql too - see `docs/mkit-sql-integration.md`.)
   - **the file exists** - read and classify it:
     - **held** - another live process owns it, or it names another *host* (liveness of a remote process can't be
       checked, so it is always respected). Do not write. Report `pid host role endpoint` to the user.
     - **stale** - same host and the pid is not running (a *zombie* - killed but not yet collected by its parent -
       is not running); or the pid runs but its start time differs from `start` (pid reused); or the file is empty or
       garbled and older than 10 seconds (its creator died between creating and writing it).
     - **ours** - same pid and host (left by an earlier run of this very process).
3. **Take over** a stale/ours lock under the mutex file `<database>.lock.takeover`, so that processes that all see
   the same stale lock cannot each delete the winner's fresh one:
   1. create the mutex exclusively; if it exists, wait a moment (~25 ms) and start over; a mutex older than
      **30 seconds** was abandoned by a crash and is deleted;
   2. with the mutex held, **classify the lock again**; only if it is still stale/ours (or gone): delete it and
      create `<database>.lock` exclusively, write your line;
   3. delete the mutex. Exactly one process wins; the others loop back to step 1 and find a live owner.
   Both implementations use the same mutex name, so they exclude each other; a process that cannot get the lock
   after a few rounds reports "starting at the same moment, please repeat".
4. When your create succeeds, you may delete a takeover mutex older than 30 s that a crashed process left.

**Release** (on close): delete `<database>.lock` *only if it still holds exactly what you wrote*. If it was replaced,
leave it alone.

**Read-only open** takes no lock. A read-only opener may look at the lock to warn the user.

**Limits.** The lock is advisory: programs that don't follow it are not stopped. `O_EXCL` is reliable on local
file systems and modern NFS; on exotic network file systems it may not be, in which case run one server instead.
A crashed owner leaves its lock behind until the next opener finds it stale (same host) - there is no timeout for
remote owners, by design. The only time-based rules are the two abandonment limits above, compared with the local
file system clock.

## API (`store.tcl`)

    ::store::openFile path ?-readonly? ?-create?   takes/refuses the lock; error code {STORE LOCKED pid host role endpoint}
    ::store::closeFile tag                         releases our lock (only ours)
    ::store::lockInfo path                         dict: state free|ours|stale|held, pid host role endpoint
    ::store::lockedByOther tag                     for a read-only open: who holds the write lock ("" if nobody)
    set ::store::lockRole server                   before openFile: announce a long-lived owner ...
    set ::store::lockEndpoint tcp://host:port      ... and where clients should connect
    ::store::generation tag                        a number that changes on every modification and Roll Back, never repeats
                                                   (one counter for all databases and all reopenings), -1 when not open
    ::store::onClose cmd                           cmd tag is called just BEFORE a database closes (results freeze themselves)
    ::store::cacheConfigure -budget MB             derived-data cache budget (default 256 MB, env MKS_CACHE_MB; 0 = off)
    ::store::cacheStats                            entries bytes budget hits misses evictions

## Checklist for adding mkit-sql or a server

- [ ] opens databases only through `::store::openFile` (or implements the protocol above to the letter)
- [ ] a server sets `lockRole`/`lockEndpoint` before opening, and holds the file for its lifetime
- [ ] any cache of data read from the database is keyed by `::store::generation` (or by its own change counter
      that every write path bumps)
- [ ] results that read live data implement the provider contract and pass `tests/provider_contract.tcl`
- [ ] statements that change data call `::mkql::lzFreezeAll` first (or the equivalent in the new engine)
- [ ] runs `tests/test_lock_protocol.tcl` against its own lock implementation if it has one (replace the child)

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
abandoned-mutex locks are taken over (also reused pids, zombies, and processes of other users); close never removes someone
else's lock; **six processes racing** for a free lock and for the same stale lock - exactly one wins every round (with the
mutex removed, or with a vanished lock treated as unlockable, the same test fails). With `MKITSQL_DIR` set, half of the
racers are mkit-sql's implementation. `tests/test_lock_crash.tcl` kills a process at every step of acquiring, taking over
and releasing (created, written, holding the mutex, between delete and create, after release) and then runs a chaos loop:
eight processes take the lock repeatedly while the test SIGKILLs random ones; no two live processes ever hold it at once
and it is never lost. `tests/test_crash_safety.tcl` covers crash recovery of the data and read-only access.
