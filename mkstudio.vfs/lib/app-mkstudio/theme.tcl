# theme.tcl -- palettes, fonts and the custom ttk theme ("mks").
#
# Every colour in the UI comes from ::theme::c(<key>).  Plain Tk widgets
# (text, canvas, menu, ...) register a recolouring script with ::theme::reg so
# switching between dark and light re-skins the whole window live.

namespace eval ::theme {
    variable name dark
    variable c
    array set c {}
    variable registry {}
    variable palettes

    set palettes(dark) {
        bg #14161b      panel #1a1d24     surface #1e222a   editor #181b21
        raised #262b35  hover #2b313d     border #2b313c    fg #d5d9e0
        dim #8a93a5     faint #5b6475     accent #5b9dff    accentFg #0b1220
        accentDim #2d4f86  sel #284e88    selFg #ffffff     ok #4cc38a
        warn #e2b04a    bad #f06b6b       stripe #1b1f26    headBg #20242d
        gutter #4d5565  curline #1d222c   kw #7aa8ff        str #e6b36b
        num #9ed6a4     fn #c79bff        type #5fd0c0      op #93a0b5
        comment #667186 errbg #4a2226  badHover #f48686
        find #4d4220    findCur #9a7a1c
    }
    # WCAG-AAA style: pure black, white text, yellow accent, strong borders
    set palettes(contrast) {
        bg #000000      panel #000000     surface #000000   editor #000000
        raised #1a1a1a  hover #333333     border #ffffff    fg #ffffff
        dim #d9d9d9     faint #a6a6a6     accent #ffd400    accentFg #000000
        accentDim #0a2a6e  sel #ffd400    selFg #000000     ok #4dff88
        warn #ffd400    bad #ff7b7b       stripe #0f0f0f    headBg #1a1a1a
        gutter #c8c8c8  curline #1c1c1c   kw #7cc0ff        str #ffb347
        num #7dff9a     fn #e6a8ff        type #5ff0e0      op #ffffff
        comment #b8b8b8 errbg #5a0000     badHover #ffa3a3
        find #5a4a00    findCur #ffd400
    }
    set palettes(light) {
        bg #eceef2      panel #f5f6f9     surface #ffffff   editor #ffffff
        raised #e3e6ec  hover #dde2ea     border #d3d8e1    fg #1f2430
        dim #5d6677     faint #98a1b2     accent #2b6be0    accentFg #ffffff
        accentDim #c9dcfb  sel #bcd4fb    selFg #0b1220     ok #1a8f5a
        warn #a86f00    bad #c93a3a       stripe #f6f8fb    headBg #eef0f5
        gutter #a3abbb  curline #f1f5fd   kw #1f5fd1        str #b0561a
        num #1b7f3b     fn #7a3fc9        type #0d7f77      op #5d6677
        comment #8a93a3 errbg #fbdcdc  badHover #b02f2f
        find #fdf0c2    findCur #f5c84c
    }
}

proc ::theme::pick {candidates fallback} {
    set have [string tolower [font families]]
    foreach f $candidates {
        if {[lsearch -exact $have [string tolower $f]] >= 0} { return $f }
    }
    return $fallback
}

proc ::theme::initFonts {} {
    set ui [pick {"Segoe UI Variable Text" "Segoe UI" "SF Pro Text" "Helvetica Neue" "Inter" \
        "Noto Sans" "Cantarell" "Ubuntu" "DejaVu Sans" "Liberation Sans"} \
        [font actual TkDefaultFont -family]]
    set mono [pick {"Cascadia Code" "Cascadia Mono" "JetBrains Mono" "Consolas" "SF Mono" "Menlo" \
        "Fira Code" "Source Code Pro" "Noto Sans Mono" "DejaVu Sans Mono" "Liberation Mono" "Courier New"} \
        [font actual TkFixedFont -family]]
    catch {font delete MkUI MkUIBold MkSmall MkTitle MkMono MkHuge}
    font create MkUI     -family $ui -size 10
    font create MkUIBold -family $ui -size 10 -weight bold
    font create MkSmall  -family $ui -size 9
    font create MkTitle  -family $ui -size 13 -weight bold
    font create MkHuge   -family $ui -size 22 -weight bold
    font create MkMono   -family $mono -size 11
    foreach f {TkDefaultFont TkTextFont TkMenuFont TkHeadingFont TkCaptionFont TkTooltipFont} {
        catch {font configure $f -family $ui -size 10}
    }
}

# Display scale: 1.0 at the classic 96 dpi (Tk scaling 1.333); 2.0 on a 2x display.
# Fixed pixel sizes go through px so they grow with the fonts instead of clipping.
proc ::theme::scale {} {
    set s [expr {[tk scaling] / 1.3333333}]
    return [expr {$s < 1.0 ? 1.0 : $s}]
}
proc ::theme::px {n} { return [expr {int(round($n * [scale]))}] }
# a row height that fits the UI font with comfortable padding
proc ::theme::rowHeight {{extra 10}} {
    return [expr {max([px 24], [font metrics MkUI -linespace] + $extra)}]
}

# colour lookup
proc ::theme::color {key} { variable c ; return $c($key) }

# Register a script to (re)apply colours to a plain Tk widget.  %w is replaced
# by the widget path.  The script runs immediately and on every theme change.
proc ::theme::reg {w script} {
    variable registry
    lappend registry [list $w $script]
    uplevel #0 [string map [list %w $w] $script]
}

proc ::theme::apply {which} {
    variable name ; variable c ; variable palettes ; variable registry
    set name $which
    array set c $palettes($which)
    styles
    # recolour registered plain-Tk widgets, forgetting the ones that are gone
    set live {}
    foreach r $registry {
        lassign $r w script
        if {![winfo exists $w]} continue
        lappend live $r
        catch {uplevel #0 [string map [list %w $w] $script]}
    }
    set registry $live
    . configure -background $c(bg)
    option add *Menu.background $c(raised) ; option add *Menu.foreground $c(fg)
    event generate . <<ThemeChanged>>
}

proc ::theme::init {} {
    initFonts
    ttk::style theme create mks -parent clam
    ttk::style theme use mks
    option add *Menu.font MkUI
    option add *TCombobox*Listbox.font MkUI
}

# ---------------------------------------------------------------------------
proc ::theme::styles {} {
    variable c
    ttk::style theme use mks
    ttk::style configure . -background $c(bg) -foreground $c(fg) -font MkUI \
        -bordercolor $c(border) -darkcolor $c(bg) -lightcolor $c(bg) -troughcolor $c(panel) \
        -focuscolor $c(accent) -selectbackground $c(sel) -selectforeground $c(selFg) \
        -insertcolor $c(accent) -fieldbackground $c(editor) -relief flat -borderwidth 0
    ttk::style map . -foreground [list disabled $c(faint)] -background [list disabled $c(bg)]

    # frames -----------------------------------------------------------------
    ttk::style configure TFrame -background $c(bg)
    ttk::style configure Panel.TFrame -background $c(panel)
    ttk::style configure Surface.TFrame -background $c(surface)
    ttk::style configure Editor.TFrame -background $c(editor)
    ttk::style configure Raised.TFrame -background $c(raised)
    ttk::style configure Line.TFrame -background $c(border)
    ttk::style configure Accent.TFrame -background $c(accent)

    # labels -----------------------------------------------------------------
    ttk::style configure TLabel -background $c(bg) -foreground $c(fg)
    ttk::style configure Panel.TLabel -background $c(panel)
    ttk::style configure Surface.TLabel -background $c(surface)
    ttk::style configure Dim.TLabel -background $c(bg) -foreground $c(dim)
    ttk::style configure SurfaceDim.TLabel -background $c(surface) -foreground $c(dim)
    ttk::style configure PanelDim.TLabel -background $c(panel) -foreground $c(dim)
    ttk::style configure Title.TLabel -background $c(surface) -foreground $c(fg) -font MkTitle
    ttk::style configure Huge.TLabel -background $c(surface) -foreground $c(fg) -font MkHuge
    ttk::style configure Section.TLabel -background $c(panel) -foreground $c(dim) -font MkSmall
    ttk::style configure Status.TLabel -background $c(accentDim) -foreground $c(fg) -font MkSmall
    ttk::style configure StatusDim.TLabel -background $c(accentDim) -foreground $c(dim) -font MkSmall
    ttk::style configure Error.TLabel -background $c(surface) -foreground $c(bad)
    ttk::style configure Raised.TLabel -background $c(raised) -foreground $c(fg)
    ttk::style configure RaisedDim.TLabel -background $c(raised) -foreground $c(dim) -font MkSmall
    ttk::style configure ToolRaised.TButton -background $c(raised) -foreground $c(fg) -padding {6 2} \
        -borderwidth 0 -focusthickness 2 -focuscolor $c(accent)
    ttk::style map ToolRaised.TButton -background [list pressed $c(border) active $c(hover)]
    ttk::style configure Link.TLabel -background $c(surface) -foreground $c(accent)

    # buttons ----------------------------------------------------------------
    ttk::style configure TButton -background $c(raised) -foreground $c(fg) -padding {12 5} \
        -borderwidth 1 -bordercolor $c(border) -focusthickness 2 -focuscolor $c(accent) -anchor center
    ttk::style map TButton -background [list pressed $c(border) active $c(hover) disabled $c(panel)] \
        -bordercolor [list focus $c(accent)]
    ttk::style configure Tool.TButton -background $c(bg) -foreground $c(fg) -padding {7 5} \
        -borderwidth 0 -focusthickness 2 -focuscolor $c(accent)
    ttk::style map Tool.TButton -background [list pressed $c(border) active $c(hover) disabled $c(bg)] \
        -foreground [list disabled $c(faint)]
    ttk::style configure ToolPanel.TButton -background $c(panel) -foreground $c(dim) -padding {5 3} \
        -borderwidth 0 -focusthickness 2 -focuscolor $c(accent)
    ttk::style map ToolPanel.TButton -background [list pressed $c(border) active $c(hover)] \
        -foreground [list active $c(fg)]
    ttk::style configure ToolSurface.TButton -background $c(surface) -foreground $c(fg) -padding {8 4} \
        -borderwidth 0 -focusthickness 2 -focuscolor $c(accent)
    ttk::style map ToolSurface.TButton -background [list pressed $c(border) active $c(hover)] \
        -foreground [list disabled $c(faint)]
    ttk::style configure Accent.TButton -background $c(accent) -foreground $c(accentFg) -padding {14 6} \
        -borderwidth 0 -focusthickness 2 -focuscolor $c(accent) -font MkUIBold
    ttk::style map Accent.TButton -background [list pressed $c(kw) active $c(kw) disabled $c(raised)] \
        -foreground [list disabled $c(faint)]
    ttk::style configure Run.TButton -background $c(bg) -foreground $c(ok) -padding {9 5} \
        -borderwidth 0 -focusthickness 2 -focuscolor $c(accent) -font MkUIBold
    ttk::style map Run.TButton -background [list pressed $c(border) active $c(hover) disabled $c(bg)] \
        -foreground [list disabled $c(faint)]
    ttk::style configure Danger.TButton -background $c(bad) -foreground #ffffff -padding {14 6} \
        -borderwidth 0 -focusthickness 2 -focuscolor $c(accent) -font MkUIBold
    ttk::style map Danger.TButton -background [list pressed $c(bad) active $c(badHover)]
    ttk::style configure Link.TButton -background $c(surface) -foreground $c(accent) -padding {2 2} \
        -borderwidth 0 -focusthickness 2 -focuscolor $c(accent) -anchor w
    ttk::style map Link.TButton -background [list active $c(surface)] -foreground [list active $c(kw)]

    # checks, entries ----------------------------------------------------------
    ttk::style configure Surface.TCheckbutton -background $c(surface) -foreground $c(fg) \
        -indicatorbackground $c(editor) -indicatorforeground $c(accent) -focusthickness 2 -focuscolor $c(accent)
    ttk::style map Surface.TCheckbutton -background [list active $c(surface)]
    ttk::style configure TCheckbutton -background $c(bg) -indicatorbackground $c(editor) \
        -indicatorforeground $c(accent) -focusthickness 2 -focuscolor $c(accent)
    ttk::style configure TEntry -fieldbackground $c(editor) -foreground $c(fg) -bordercolor $c(border) \
        -lightcolor $c(editor) -darkcolor $c(editor) -padding {6 4} -insertcolor $c(fg) -borderwidth 1
    ttk::style map TEntry -bordercolor [list focus $c(accent)] -lightcolor [list focus $c(accent)] \
        -darkcolor [list focus $c(accent)]
    ttk::style configure TCombobox -fieldbackground $c(editor) -background $c(raised) -foreground $c(fg) \
        -bordercolor $c(border) -arrowcolor $c(dim) -lightcolor $c(editor) -darkcolor $c(editor) \
        -padding {6 4} -borderwidth 1 -insertcolor $c(fg) -selectbackground $c(editor) -selectforeground $c(fg)
    ttk::style map TCombobox -bordercolor [list focus $c(accent)] \
        -fieldbackground [list readonly $c(editor)] -foreground [list readonly $c(fg)] \
        -background [list active $c(hover)]
    option add *TCombobox*Listbox.background $c(raised)
    option add *TCombobox*Listbox.foreground $c(fg)
    option add *TCombobox*Listbox.selectBackground $c(accent)
    option add *TCombobox*Listbox.selectForeground $c(accentFg)
    option add *TCombobox*Listbox.borderWidth 0
    option add *TCombobox*Listbox.relief flat

    # scrollbars (slim, no arrows) ---------------------------------------------
    foreach o {Vertical Horizontal} {
        set side [expr {$o eq "Vertical" ? "ns" : "ew"}]
        ttk::style layout $o.TScrollbar [list $o.Scrollbar.trough -sticky $side -children \
            [list $o.Scrollbar.thumb -expand 1 -sticky nswe]]
    }
    ttk::style configure TScrollbar -troughcolor $c(bg) -background $c(raised) -bordercolor $c(bg) \
        -lightcolor $c(raised) -darkcolor $c(raised) -arrowsize 0 -gripcount 0 -width [px 11] -borderwidth 0
    ttk::style map TScrollbar -background [list pressed $c(faint) active $c(faint)] \
        -lightcolor [list pressed $c(faint) active $c(faint)] -darkcolor [list pressed $c(faint) active $c(faint)]

    # paned window ---------------------------------------------------------------
    ttk::style configure TPanedwindow -background $c(border)
    ttk::style configure Sash -sashthickness 3 -gripcount 0 -background $c(border) \
        -lightcolor $c(border) -darkcolor $c(border) -bordercolor $c(border)

    # treeview ---------------------------------------------------------------------
    ttk::style configure Treeview -background $c(surface) -fieldbackground $c(surface) -foreground $c(fg) \
        -rowheight [rowHeight] -borderwidth 0 -bordercolor $c(surface) -lightcolor $c(surface) -darkcolor $c(surface) \
        -indent [px 16]
    ttk::style map Treeview -background [list selected $c(sel)] -foreground [list selected $c(selFg)]
    ttk::style layout Treeview {Treeview.padding -sticky nswe -children {Treeview.treearea -sticky nswe}}
    ttk::style configure Panel.Treeview -background $c(panel) -fieldbackground $c(panel) -rowheight [rowHeight] \
        -bordercolor $c(panel) -lightcolor $c(panel) -darkcolor $c(panel)
    ttk::style map Panel.Treeview -background [list selected $c(sel)] -foreground [list selected $c(selFg)]
    ttk::style layout Panel.Treeview {Treeview.padding -sticky nswe -children {Treeview.treearea -sticky nswe}}
    ttk::style configure Treeview.Heading -background $c(headBg) -foreground $c(dim) -relief flat \
        -padding {4 5 4 5} -borderwidth 0 -bordercolor $c(border) -lightcolor $c(headBg) -darkcolor $c(headBg) \
        -font MkSmall
    ttk::style map Treeview.Heading -background [list active $c(hover)] -foreground [list active $c(fg)]
    ttk::style configure Grid.Treeview -rowheight [rowHeight]
    ttk::style configure Horizontal.TProgressbar -background $c(accent) -troughcolor $c(raised) -borderwidth 0 \
        -bordercolor $c(border) -lightcolor $c(accent) -darkcolor $c(accent)
    ttk::style layout Grid.Treeview {Treeview.padding -sticky nswe -children {Treeview.treearea -sticky nswe}}
    ttk::style map Grid.Treeview -background [list selected $c(sel)] -foreground [list selected $c(selFg)]
}

# Style a plain tk menu.
proc ::theme::menu {m} {
    variable c
    $m configure -background $c(raised) -foreground $c(fg) -activebackground $c(accent) \
        -activeforeground $c(accentFg) -relief flat -borderwidth 1 -font MkUI \
        -disabledforeground $c(faint) -activeborderwidth 0
}
