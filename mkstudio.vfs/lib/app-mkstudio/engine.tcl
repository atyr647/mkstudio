# engine.tcl -- the ONE seam between MK Studio's UI and its query language.
#
# The UI never parses or interprets query text itself.  It only calls the procs
# and reads the variables below.  The built-in dialect (mkql.tcl) is a small
# stand-in so the app is usable on its own; to plug in a different language
# (for example a standard-SQL-to-Metakit engine), replace the bodies of the two
# procs and set the variables.  Nothing else in the UI needs to change.
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
    variable name "MKQL (built-in)"
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
