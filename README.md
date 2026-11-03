# MK Studio

A SQL-Server-Management-Studio-style workbench for **Metakit** databases, written
entirely in Tcl/Tk and designed to live inside a **starpack** (one executable).

* **Object Explorer** - databases -> views -> columns, subviews nested; double-click a view to edit its rows
* **Edit Rows** - spreadsheet-style editing straight into the database, with friendly type validation; double-click a `> N rows` cell to open a subview
* **Designer** - add, edit (rename / retype) and drop columns and subviews
* **Query windows** - tabbed editor with highlighting and multiple result tabs
* **Commit / Roll Back** - changes stay in memory until you commit (files are opened `-nocommit`)
* Dark and light themes, CSV import / export, script save / open

### The query language is pluggable

The UI never parses SQL itself. The query window calls only these procs in `mkql.tcl`:

    ::mkql::parseScript text   ->  list of {ast firstPos endPos statementText}   (errors carry -errorcode {MKQL SYNTAX pos len})
    ::mkql::execStatement ast defaultDb  ->  {kind rowset cols .. types .. rows .. rowids .. drill .. source .. truncated 0}
                                             or {kind message text ..}

`mkql.tcl` is a small built-in stand-in dialect so the app is usable today. Replace those two
procs with your standard-SQL-to-Metakit engine and nothing else needs to change. The data
grid and designer talk to `store.tcl` directly and do not use the query language at all.

## Layout

```
mkstudio.vfs/main.tcl                entry point (starkit)
mkstudio.vfs/lib/app-mkstudio/       store.tcl  the only file that calls mk::*
                                     mkql.tcl   lexer, parser, executor
                                     theme / icons / widgets / grid / editor / explorer / docs / app
tests/                               engine tests, GUI tests, a pure-Tcl mk:: stand-in (tests only)
build.sh                             wraps everything into a starpack
```

## Download / build the starpack

A ready-built Linux x86_64 starpack is in `dist/mkstudio-linux-x86_64` (single file, includes Tcl/Tk 8.6.3 and Metakit):

    ./dist/mkstudio-linux-x86_64 [file.mk ...]

Rebuild it (no sdx needed - `tools/wrap.tcl` does what `sdx wrap` does):

    ./build.sh                                  # -> dist/mkstudio-linux-x86_64
    RUNTIME=path/to/other-tclkit ./build.sh dist/mkstudio-other     # another platform's runtime (needs Tk + Mk4tcl)

`tools/tclkit-8.6.3-linux-x86_64` is the unmodified tclkit from tclkits.rkeene.org
(SHA1 36b5cb68899cfcb79417a29f9c6d8176ebae0d24).

## Tests

    tools/tclkit-8.6.3-linux-x86_64 tests/test_mkql.tcl                  # mock mk::  (tclsh also works)
    REAL_MK=1 tools/tclkit-8.6.3-linux-x86_64 tests/test_mkql.tcl        # real Metakit
    REAL_MK=1 xvfb-run tools/tclkit-8.6.3-linux-x86_64 tests/gui_logic.tcl
    tools/tclkit-8.6.3-linux-x86_64 tests/persist.tcl                    # commit / uncommitted-close on real files
    xvfb-run -s "-screen 0 1440x900x24" wish tests/shoot.tcl main out.png  # screenshot (add REAL_MK=1 under a tclkit)

## Verification status

Verified against the **real Mk4tcl 2.4.9.7** in tclkit 8.6.3 on Linux: all 69 engine checks, the
16 UI-logic checks, commit / roll-back / `-nocommit` persistence, and the packaged starpack
launching standalone and opening a real file. Not yet tested: Windows and macOS runtimes, and
the classic Tcl 8.5 tclkits (the code sticks to 8.5 syntax, but that is unexercised).

Metakit notes: there is no NULL (NULL means empty string); renaming or retyping a column
copies its data into a new column that ends up last in the layout; a dropped view stays listed
until commit, so `store.tcl` treats views with an empty layout as gone.
