# MK Studio

A SQL-Server-Management-Studio-style workbench for **Metakit** databases, written
entirely in Tcl/Tk and designed to live inside a **starpack** (one executable).

* **Object Explorer** – databases -> views -> columns, with subviews nested; lazy-loaded, context menus
* **Query windows** – tabbed editor, syntax highlighting, completion (`Ctrl+Space`), error underlining
* **MKQL** – a SQL dialect shaped around Metakit (views, typed columns, *subviews*). See *Help -> MKQL Reference*
* **Results grid** – multiple result tabs, sortable, copy / CSV export, double-click a `> N rows` cell to open the subview
* **Edit Rows** – spreadsheet-style editing straight into the database, with type validation
* **Designer** – add / rename / retype / drop columns and subviews; every change shown as MKQL
* **Commit / Roll Back** – Metakit changes stay in memory until you commit (files are opened `-nocommit`)
* Properties pane, dark and light themes, CSV import, script save/open

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
