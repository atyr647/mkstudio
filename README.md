# MK Studio

A SQL-Server-Management-Studio-style workbench for **Metakit** databases, written entirely in
Tcl/Tk and shipped as a **starpack**: one self-contained executable (Tcl, Tk and Metakit
included) that you can copy anywhere and run.

![main](docs/screenshots/main.png)

## What it does

- **Object Explorer** - databases, views, columns; subviews nested; view filter; Enter or double-click opens a view
- **Edit Rows** - spreadsheet-style editing with type validation, paging for huge views, **undo / redo**
  (edits, added rows, deleted rows including their subview contents), double-click a `> N rows` cell to open a subview
- **Bytes columns** - size and hex preview in the grid; a hex viewer with export, replace-from-file and clear
- **Designer** - add, rename, retype, drop columns and subviews (a renamed column keeps its position)
- **Query windows** - syntax highlighting, completion, Find, multiple result tabs, cancel, error underlining
- **Commit / Roll Back** - files are opened `-nocommit`: nothing reaches disk until you commit
- **Safety** - refuses files that aren't Metakit databases; read-only databases disable every write control
- Dark, light and high-contrast themes; scales with display DPI; full keyboard operation (`F1` lists shortcuts)
- CSV import and export, script save / open

More screenshots: [`docs/screenshots/`](docs/screenshots/) (all captured from the real app on real Metakit).

## The query language is pluggable

The UI never parses query text. It talks to one small seam, [`engine.tcl`](mkstudio.vfs/lib/app-mkstudio/engine.tcl),
which documents the exact contract (`::engine::parseScript`, `::engine::execute`, and the keyword / token /
cancel variables). `mkql.tcl` is a small built-in dialect so the app is usable on its own; a
standard-SQL-to-Metakit engine replaces it by redefining those two procs. The data grid and
designer use `store.tcl` directly and don't depend on the language at all.

    REAL_MK=1 tools/ext/tclkit-8.6.3-linux-x86_64 tests/engine_contract.tcl     # 38 checks against the contract

Edit the `stmts` array at the top of that test for your dialect and point it at your engine.

## Get it / build it

    tools/fetch-runtimes.sh             # download SHA1-verified tclkit runtimes into tools/ext/
    ./build.sh                          # Linux  -> dist/mkstudio-linux-x86_64
    ./build.sh all                      # + Windows (.exe) and macOS (universal)
    ./dist/mkstudio-linux-x86_64 [file.mk ...]

Binaries are not stored in git. `.github/workflows/build.yml` runs the whole test matrix, builds all
three starpacks and uploads them as artifacts (and attaches them to a release when you push a `v*` tag).
Wrapping needs no `sdx`: `tools/wrap.tcl` appends the application's Metakit payload to a runtime.

Run from source (needs a Tk with Mk4tcl, e.g. a tclkit): `tclkit mkstudio.vfs/main.tcl [file.mk ...]`

## Verification

| | status |
|---|---|
| Engine, UI logic, persistence, engine contract on **real Metakit** (Mk4tcl 2.4.9.7) | Tcl **8.6.3** and **8.5.17** - all pass |
| Real-world file (a tclkit's own boot database: subviews + binary columns) | opens, browses, hex view works |
| 500,000-row file | see numbers below |
| Packaged Linux starpack | launches, opens a database, no errors |
| Windows and macOS starpacks | built; embedded payload verified byte-identical; format checked (PE32+ GUI, universal Mach-O). **Not executed** - I had no Windows or macOS machine. CI builds them, but running them is on you |
| HiDPI | verified with Tk scaling 2.0 on Linux; Windows/macOS DPI behaviour depends on the runtime's manifest |
| Screen readers | **not supported**: Tk has no accessibility API. Keyboard operation, visible focus and a high-contrast theme are provided instead |

Tests (all in `tests/`): `lint.tcl` (no proc shadows a Tcl/Tk command, ASCII-only sources, no 8.6-only commands),
`test_mkql.tcl`, `engine_contract.tcl`, `persist.tcl`, `gui_logic.tcl` (35 checks incl. every popup menu and undo),
`verify_payload.tcl`, `smoke_starpack.sh`, `bench.tcl`, and `shoot.tcl` for screenshots.
A pure-Tcl `mk::` stand-in (`mock_mk4tcl.tcl`) lets the suite also run without Metakit; it is test-only.

## Performance and limits (500,000 rows, 29 MB, Linux)

| operation | time |
|---|---|
| open file, list views / layout | ~40 ms |
| open a view in the editor (first 5,000 rows), turn a page | ~160 ms, ~80 ms |
| `SELECT ... LIMIT 100` | ~10 ms |
| full-scan `WHERE`, `GROUP BY` | ~6-7 s (cancellable) |
| `ORDER BY` with `LIMIT` | ~11 s (was 41 s) |
| `UPDATE` 10,000 rows of a string column | ~26 s |

The slow `UPDATE` is Metakit itself: rewriting a variable-length string in a large view shifts the rest of
the column, so each write costs more the earlier it is in the view. The app keeps the UI responsive, lets you
cancel, skips writes that change nothing, and a Roll Back undoes a cancelled run. Sorting a result by clicking a
column header sorts the rows currently loaded (the current page in the editor).

## Notes on Metakit

There is no NULL (it means the empty string). A view you drop stays listed by Metakit until commit, so views
with an empty layout are treated as gone. `mk::view layout` on a subview path returns the *top-level* layout, so
`store.tcl` walks the nested definition itself. `mk::row insert` only takes a count, so restoring a row inserts a
blank one and fills it. Each of these is covered by a test.

## Layout

```
mkstudio.vfs/main.tcl                 entry point (starkit)
mkstudio.vfs/lib/app-mkstudio/
    store.tcl     the ONLY file that calls mk::*
    engine.tcl    the query-language seam (documented contract)
    mkql.tcl      built-in stand-in dialect
    theme icons menus widgets grid editor explorer docs app
tests/  tools/  build.sh  .github/workflows/build.yml
```
