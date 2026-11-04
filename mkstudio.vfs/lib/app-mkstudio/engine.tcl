# engine.tcl -- the ONE seam between MK Studio's UI and its query language.
#
# The UI never parses or interprets query text itself.  It only calls the procs
# and reads the variables below.  The procs and variables defined at the bottom
# of this file belong to the built-in dialect (mkql.tcl), a small engine that the
# tests use as a stand-in and a reference.  The program normally runs mkit-sql
# (standard SQL; mkstudio.vfs/lib/mkitsql), whose engine_studio.tcl REPLACES the
# bodies of the two procs and sets the variables - that is all it takes to plug in
# another language; nothing else in the UI changes.  loader.tcl picks the engine
# (MKS_ENGINE=mkql selects the built-in dialect).  The error code of a syntax
# error stays {MKQL SYNTAX ...} whatever the engine: it is the editor's contract.
# `tests/engine_contract.tcl` checks that an engine honours this contract.
#
# ---- procs -------------------------------------------------------------------
#
#   ::engine::parseScript text
#       Parse a whole script WITHOUT running it.  Returns a list with one entry
#       per statement:  {handle firstChar endChar statementText}
#       (`handle` is opaque to the UI; first/end are character offsets into
#       `text`, endChar exclusive).  On a syntax error raise an error whose
#       -errorcode is  {MKQL SYNTAX <charOffset> <length>}  so the editor can
#       underline the offending token; any other error just shows its message.
#
#   ::engine::execute handle defaultDb
#       Run one parsed statement against the open databases (see ::store for
#       the Metakit primitives; `defaultDb` is the tag chosen in the toolbar,
#       possibly empty).  Returns a dict, either
#
#         {kind rowset  cols {names..}  types {S I L F D B V N ""..}
#          rows {{v v ..} ..}  rowids {..}  drill {colIndex subviewName ..}
#          source mkpath  truncated 0|1  editable 0|1}
#              - types has one letter per column: S I L F D B (Metakit types),
#                V (subview, shown as "> N rows"), N (derived number) or ""
#              - rowids: store row index per row ({} when rows are not 1:1
#                with a view, e.g. aggregates); drill: columns that hold subviews
#              - source: Metakit path ("tag.view") of a plain SELECT, else ""
#              - OPTIONAL  provider <command prefix>:  instead of holding every row in `rows`
#                (leave it {}), an engine may hand the UI a streaming data source, so a result of
#                millions of rows costs no memory until it is looked at.  The UI calls
#                    {*}$provider count            -> number of rows
#                    {*}$provider rows first n     -> rows first .. first+n-1 (display-ready lists)
#                    {*}$provider rowid p          -> store row index of row p ("" if none)
#                    {*}$provider cell p ci        -> one value
#                    {*}$provider sort ci dir type -> reorder by a column (dir asc|desc); may raise
#                    {*}$provider stale            -> 1 when the underlying data changed since the
#                                                     query ran (the UI shows a banner)
#                    {*}$provider freeze           -> keep the rows as they are now (called by the
#                                                     engine itself before it changes data)
#                    {*}$provider destroy          -> the UI is finished with it
#                `put` is accepted and may be ignored.  A provider reading live data MUST report
#                `stale` once the data changed (use ::store::generation) - see docs/CONCURRENCY.md.
#
#         {kind message  text "..."  ?affected N?  ?use dbTag?}
#              - `use` switches the query window's database
#
#       Raise an error to report a failure (same -errorcode rule as above;
#       without it the whole statement is underlined).
#
# ---- variables ---------------------------------------------------------------
#
#   ::engine::name        dialect name, shown in the About box
#   ::engine::keywords    words to highlight / complete as keywords
#   ::engine::functions   words to highlight / complete as functions
#   ::engine::types       type names to highlight (e.g. INT TEXT)
#   ::engine::tokenRe     highlighter regexp with 8 groups, in this order:
#                         line comment | block comment | 'string' | "identifier" |
#                         number | word | operator | stray character
#   ::engine::maxRows     soft cap on un-sorted result sets
#   ::engine::progressHook  script the engine must run every few hundred rows of
#                         any long loop (it keeps the UI alive)
#   ::engine::cancel      the UI sets this to 1 when the user presses Stop; the
#                         engine must check it in the same loops and abort
#                         (reset it to 0 when a statement starts)

namespace eval ::engine {
    variable name "MKQL (built-in dialect)"
    variable keywords {}
    variable functions {}
    variable types {STRING TEXT INT INTEGER LONG BIGINT FLOAT REAL DOUBLE BYTES BLOB}
    variable tokenRe {}
    variable maxRows 100000
    variable progressHook {}
    variable cancel 0
}

proc ::engine::parseScript {text} { ::mkql::parseScript $text }
proc ::engine::execute {handle defaultDb} { ::mkql::execStatement $handle $defaultDb }
