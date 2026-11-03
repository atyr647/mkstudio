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
6. **Derived data is keyed by generation.** Anything computed from a database (sorted orders, column copies,
   query results that read live data) is valid only for the generation it was built from
   (`::store::generation`, bumped by every change and by Roll Back). A component that caches must check it;
   a streaming result must report itself `stale` once the generation moves (see the `provider` contract in
   `engine.tcl`). The engine freezes its own live results before it changes data.
7. **One process, one door.** Inside a process, only `store.tcl` calls `mk::*`, so the rules are enforced
   in one place. An engine that opens files itself must call `::store::openFile` (or implement the protocol).

## The lock protocol

The lock is a file next to the database: `<database>.lock` (for `sales.mk`, `sales.mk.lock`).

**Content** - one line of text, space separated:

    <pid> <host> [<role> [<endpoint>]]

| field | meaning |
|---|---|
| `pid` | process id of the owner (decimal) |
| `host` | name of the machine the owner runs on (`info hostname`) |
| `role` | optional: what the owner is, e.g. `server`; `-` means none (when only `endpoint` is given) |
| `endpoint` | optional: where to reach it, e.g. `tcp://db.example:5433` |

**Acquire** (a writer, before opening the database for writing):

1. Create `<database>.lock` with *exclusive create* (`O_CREAT|O_EXCL`; Tcl: `open $f {WRONLY CREAT EXCL}`) and
   write the line above. If that succeeds you own the database.
2. If the file exists, read it and classify it:
   - **held** - another live process owns it, or it names another *host* (liveness of a remote process can't be
     checked, so it is always respected). Do not write. Report `pid host role endpoint` to the user.
   - **stale** - same host and the pid is not running; or the file is empty/garbled and older than 5 seconds
     (its creator died between creating and writing it). Take it over (next step).
   - **ours** - same pid and host (left by an earlier run of this very process). Take it over.
3. **Take over** under a guard so that several processes that all see the same stale lock cannot each delete
   the winner's fresh one:
   1. create `<database>.lock.guard` exclusively; if it exists wait (poll ~40 ms, up to ~2 s); a guard older than
      10 seconds was abandoned by a crash and is deleted;
   2. with the guard held, **classify the lock again**; only if it is still stale/ours delete it;
   3. delete the guard, then go back to step 1 (create exclusively). Exactly one process wins.

**Release** (on close): delete `<database>.lock` *only if it still names you*. If it was replaced, leave it alone.

**Read-only open** takes no lock. A read-only opener may look at the lock to warn the user.

**Limits.** The lock is advisory: programs that don't follow it are not stopped. `O_EXCL` is reliable on local
file systems and modern NFS; on exotic network file systems it may not be, in which case run one server instead.
A crashed owner leaves its lock behind until the next opener finds it stale (same host) - there is no timeout for
remote owners, by design. Clock skew does not matter (no timestamps are compared except the 5 s / 10 s abandonment
rules, both against the local file system clock).

## API (`store.tcl`)

    ::store::openFile path ?-readonly? ?-create?   takes/refuses the lock; error code {STORE LOCKED pid host role endpoint}
    ::store::closeFile tag                         releases our lock (only ours)
    ::store::lockInfo path                         dict: state free|ours|stale|held, pid host role endpoint
    ::store::lockedByOther tag                     for a read-only open: who holds the write lock ("" if nobody)
    set ::store::lockRole server                   before openFile: announce a long-lived owner ...
    set ::store::lockEndpoint tcp://host:port      ... and where clients should connect
    ::store::generation tag                        changes on every modification and Roll Back

## Checklist for adding mkit-sql or a server

- [ ] opens databases only through `::store::openFile` (or implements the protocol above to the letter)
- [ ] a server sets `lockRole`/`lockEndpoint` before opening, and holds the file for its lifetime
- [ ] any cache of data read from the database is keyed by `::store::generation` (or by its own change counter
      that every write path bumps)
- [ ] results that read live data implement `stale` and `freeze` of the provider contract
- [ ] statements that change data call `::mkql::lzFreezeAll` first (or the equivalent in the new engine)
- [ ] runs `tests/test_lock_protocol.tcl` against its own lock implementation if it has one (replace the child)

## What is tested

`tests/test_lock_protocol.tcl`: the lock file format; a lock written by a foreign implementation is respected
(and left untouched), including `role`/`endpoint` in the message and error code; stale, empty-and-old and
abandoned-guard locks are taken over; close never removes someone else's lock; **six processes racing** for a free
lock and for the same stale lock - exactly one wins every round (with the guard removed the same test fails: three
or four processes "won" at once). `tests/test_crash_safety.tcl` covers crash recovery and read-only access.
