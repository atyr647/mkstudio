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

## Build the starpack

You need a tclkit runtime that includes Tk and Metakit, and `sdx.kit`:

    ./build.sh path/to/tclkit-runtime path/to/sdx.kit mkstudio

## Run from source

    wish mkstudio.vfs/main.tcl [file.mk ...]          # needs a Tk that has Mk4tcl, e.g. a tclkit
    wish mkstudio.vfs/main.tcl --mock                 # development only: pure-Tcl mk:: stand-in

## Tests

    tclsh tests/test_mkql.tcl                         # query engine (69 checks)
    xvfb-run wish tests/gui_logic.tcl                 # UI logic
    xvfb-run wish tests/shoot.tcl main out.png        # screenshot of the running app

## Verification status

Developed and tested on Tcl/Tk 8.6 against `tests/mock_mk4tcl.tcl`, a stand-in that
follows the documented `mk::` semantics. **It has not yet been run against the real
Mk4tcl, and no starpack has been built**, because no tclkit was available in the
build environment. The code is kept to Tcl 8.5 syntax for classic tclkits, and every
Metakit call is isolated in `store.tcl` so any difference is a small fix.

Metakit notes: there is no NULL (NULL means empty string); renaming or retyping a
column copies its data into a new column that ends up last in the layout.
