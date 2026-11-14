# Rows of the REPL pane, built without QML.
#
# A `Pane` shows a sequence of rows: the entries of its `RankLog`, followed by the rows of its
# `Terminal` that are not in the log. Those are the pending rows (see `VTParse.pending_rows`) and the
# screen rows that have not been emitted, down to the last row with text or the cursor row, whichever
# is lower. Screen rows are shown from the screen, so an edit to them appears at once. The pane holds a
# matrix of HTML strings with a fixed number of rows, `WINDOW_ROWS`. These are the rows of the sequence
# that start at position `top`. Refilling mutates the matrix and reports one change through the
# `notify` callback. A following pane shows the end of the sequence, or the cursor row when the cursor
# is above the last shown row; `follow_row` gives the matrix row that the view must keep in view.
#
# A selection is held in sequence positions, so it does not depend on the matrix. Log entries keep
# their positions. Rows after the log are re-based when lines leave the screen (see `sync_selection!`).
#
# The view onto the sequence is held as `view_top`, the sequence position of the row at its top, with
# `view_rows` rows visible. The scrollbar maps positions by fraction of the whole sequence: a fraction
# f in [0, 1] gives the view top `1 + round(f * (length - view_rows))`. The matrix never covers the
# whole sequence, so the view is always within it.
module PaneModel

using ..VTParse: Terminal, Cell, Style, DEFAULT_STYLE, ATTR_BOLD, ATTR_DIM, ATTR_ITALIC,
    ATTR_UNDERLINE, ATTR_REVERSE, ATTR_STRIKE, RGB_FLAG, is_alternate, row_finished, row_continues,
    screen_row, pending_rows, cursor_pos
using ..LineLog: RankLog, LogEntry, window
using ..KeyMap: KEY_PAGEUP, KEY_PAGEDOWN, KEY_HOME, KEY_END, MOD_SHIFT, MOD_CTRL, MOD_ALT, MOD_META

export Pane, WINDOW_ROWS, MARGIN_ROWS, MAX_VIEW_ROWS, DEFAULT_FG, DEFAULT_BG, attach!,
    set_screen_rows!, set_view_rows!, refresh!, resume_following!, user_scrolled!, follow_row,
    cursor_slot, html_escape,
    line_html, screen_html, cells_html, palette_hex, select_start!, select_extend!, select_extend_start!,
    select_end!, select_word!, select_line!, clear_selection!, selected_text, word_range, is_word_char,
    scroll_to_fraction!, page!, scroll_to_top!, scroll_to_bottom!, scroll_action!, scroll_action,
    scrollbar_state, top_for_fraction, thumb_position, thumb_size, page_top

# Rows in the matrix: a window of 200 rows, plus a margin of 60 rows that the view can scroll into
# before a refill. The matrix size does not depend on the terminal size, so resizing changes only
# the rows, not the model's row count.
const WINDOW_ROWS = 260
# When the visible rows come within this many rows of an edge of the matrix, the matrix is refilled.
const MARGIN_ROWS = 60
# The most rows that the view can show for scrolling. A view of this many rows, centred in the matrix
# as `refill!` centres it, leaves `MARGIN_ROWS` rows of the matrix above and below, so scrolling within
# the matrix does not refill it. A taller view would refill on every step, so `set_view_rows!` clamps.
const MAX_VIEW_ROWS = WINDOW_ROWS - 2 * MARGIN_ROWS

const DEFAULT_FG = "#c0caf5"
const DEFAULT_BG = "#1a1b26"
const DEFAULT_BG_RGB = (0x1a, 0x1b, 0x26)
const CURSOR_CSS = "color:$DEFAULT_BG;background-color:$DEFAULT_FG"
const SELECTION_CSS = "color:$DEFAULT_BG;background-color:#7aa2f7"
const RESTART_CSS = "color:#565f89"

const PALETTE16 = ("#000000", "#cd0000", "#00cd00", "#cdcd00", "#0000ee", "#cd00cd", "#00cdcd",
    "#e5e5e5", "#7f7f7f", "#ff0000", "#00ff00", "#ffff00", "#5c5cff", "#ff00ff", "#00ffff", "#ffffff")
const CUBE_LEVELS = (0x00, 0x5f, 0x87, 0xaf, 0xd7, 0xff)

# Selection state, held by `Pane`. See `select_start!` and the functions after it.
"""
    SelPos(seq, col)

A position in the sequence of rows (log entries, then the shown rows) and a column in that row.
"""
struct SelPos
    seq::Int
    col::Int
end

"""
    Selection

The anchor (where the drag or click began) and focus (where it is now) of a selection, and the state
that positions are re-based against. `dragging` is true between the press and the release. The
positions were last made current when the log had `log_length` entries, the shown rows numbered
`shown_count`, and the screen was `cols` cells wide.

`span` is true for a word or line selection, whose anchor and focus are its start and end. The next
extension by Shift-click takes its anchor from that span (see `select_extend_start!`). `extended` is
true once a Shift-click has extended the selection; such a selection stays even when its anchor and
focus are the same cell.
"""
mutable struct Selection
    anchor::SelPos
    focus::SelPos
    dragging::Bool
    log_length::Int
    shown_count::Int
    cols::Int
    span::Bool
    extended::Bool
end

"""
    Pane(log, screen_rows; notify = (pane, kind, first, last) -> nothing)

A pane onto `log` whose terminal has `screen_rows` rows. Attach a terminal with `attach!`.
`notify` is called once per refill, with `kind` `:change` and the rows `first:last` that were
replaced, which is all of them.
"""
mutable struct Pane
    const log::RankLog
    const notify::Function
    term::Union{Nothing, Terminal}
    screen_rows::Int
    rows::Matrix{String}
    top::Int
    view_top::Int
    view_rows::Int
    follow::Bool
    selection::Union{Nothing, Selection}
end

check_rows(r::Integer) = r >= 1 ? Int(r) : throw(ArgumentError("the pane needs at least 1 screen row, got $r"))

function Pane(log::RankLog, screen_rows::Integer; notify = (pane, kind, first, last) -> nothing)
    r = check_rows(screen_rows)
    p = Pane(log, notify, nothing, r, fill("", WINDOW_ROWS, 1), 1, 1, min(r, MAX_VIEW_ROWS), true, nothing)
    p.top = max_top(p)
    sync_view!(p)
    fill_rows!(p)
    return p
end

# A row after the log: the screen row it came from (0 for a pending row), its cells, and whether it
# continues the row before it. A pending row continues the pending row before it; the first row
# after the pending rows continues them when the parser records that the line goes on.
struct ShownRow
    row::Int
    cells::Vector{Cell}
    joins::Bool
end

# The rows that are not in the log. All screen rows are shown while the alternate screen is active,
# since nothing is logged then. Otherwise these are the pending rows and the screen rows that have
# not been emitted, cut after the last row with text or the cursor row, whichever is lower.
function shown_rows(p::Pane)
    t = p.term
    t === nothing && return ShownRow[]
    if is_alternate(t)
        return ShownRow[ShownRow(r, screen_row(t, r), r > 1 && row_continues(t, r)) for r in 1:t.rows]
    end
    rows = ShownRow[]
    for r in 1:t.rows
        if r == t.top
            for (k, cells) in enumerate(pending_rows(t))
                push!(rows, ShownRow(0, cells, k > 1))
            end
        end
        row_finished(t, r) && continue
        joins = row_continues(t, r) && !isempty(rows) && rows[end].row in (0, r - 1)
        push!(rows, ShownRow(r, screen_row(t, r), joins))
    end
    cursor_row = first(cursor_pos(t))
    keep = findfirst(item -> item.row == cursor_row, rows)
    keep = keep === nothing ? 0 : keep
    last_text = findlast(item -> any(c -> c.char != ' ', item.cells), rows)
    last_text === nothing || (keep = max(keep, last_text))
    return rows[1:keep]
end

seq_length(p::Pane) = length(p.log) + length(shown_rows(p))
max_top(p::Pane) = seq_length(p) - size(p.rows, 1) + 1
min_top(p::Pane) = min(1, max_top(p))
clamp_top(p::Pane, top::Integer) = clamp(Int(top), min_top(p), max_top(p))

# Position in `shown` of the cursor's screen row and the cursor column, or `nothing` when the cursor
# is hidden or its row is not shown.
function cursor_position(p::Pane, shown::Vector{ShownRow})
    t = p.term
    (t === nothing || !t.cursor_visible) && return nothing
    row, col = cursor_pos(t)
    j = findfirst(item -> item.row == row, shown)
    j === nothing && return nothing
    return (j, min(col, t.cols))
end

# Sequence position that a following pane keeps in view: the cursor row when it is above the last
# shown row, so that editing an earlier line of a multi-line input shows that line. `nothing` means
# the end of the sequence.
function follow_position(p::Pane, shown::Vector{ShownRow}, cursor)
    cursor === nothing && return nothing
    j = cursor[1]
    j < length(shown) || return nothing
    return length(p.log) + j
end

# The top of the matrix for a following pane. The matrix ends at the end of the sequence unless the
# cursor row is followed and lies more than `MARGIN_ROWS` above that end, in which case the matrix is
# placed so that the cursor row has a margin above it.
function follow_top(p::Pane, shown::Vector{ShownRow}, cursor)
    max_t = length(p.log) + length(shown) - size(p.rows, 1) + 1
    s = follow_position(p, shown, cursor)
    s === nothing && return max_t
    return min(max_t, max(min(1, max_t), s - MARGIN_ROWS))
end

function follow_top(p::Pane)
    shown = shown_rows(p)
    return follow_top(p, shown, cursor_position(p, shown))
end

function fill_rows!(p::Pane)
    t = p.term
    t === nothing || t.rows == p.screen_rows ||
        error("the terminal has $(t.rows) rows but the pane shows $(p.screen_rows)")
    N = size(p.rows, 1)
    n = length(p.log)
    shown = shown_rows(p)
    sync_selection!(p, shown)
    sel = p.selection
    total = n + length(shown)
    cursor = cursor_position(p, shown)
    lo = max(p.top, 1)
    hi = min(p.top + N - 1, n)
    entries = lo <= hi ? window(p.log, lo:hi) : LogEntry[]
    for k in 1:N
        i = p.top + k - 1
        p.rows[k, 1] = if 1 <= i <= n
            e = entries[i - lo + 1]
            entry_html(e; selected = selection_range(sel, i, entry_length(e)))
        elseif n < i <= total
            j = i - n
            col = cursor !== nothing && cursor[1] == j ? cursor[2] : nothing
            cells = shown[j].cells
            cells_html(cells; cursor_col = col, selected = selection_range(sel, i, length(cells)))
        else
            ""
        end
    end
    return p
end

function refill!(p::Pane)
    sync_view!(p)
    fill_rows!(p)
    p.notify(p, :change, 1, size(p.rows, 1))
    return p
end

# Sequence position at the top of the view when following: the end of the sequence, or the cursor row
# placed as `ListView.Contain` would place it (kept in view if it already is, else moved to the nearer
# edge), starting from the current `view_top`.
function following_view_top(p::Pane, shown::Vector{ShownRow}, len::Integer)
    max_v = max_view_top(len, p.view_rows)
    s = follow_position(p, shown, cursor_position(p, shown))
    s === nothing && return max_v
    v = p.view_top
    if s < v
        return clamp(s, 1, max_v)
    elseif s > v + p.view_rows - 1
        return clamp(s - p.view_rows + 1, 1, max_v)
    end
    return clamp(v, 1, max_v)
end

# Keeps `view_top` valid for the current sequence: placed by the follow rule when following, else
# limited to the sequence.
function sync_view!(p::Pane)
    shown = shown_rows(p)
    len = length(p.log) + length(shown)
    p.view_top = p.follow ? following_view_top(p, shown, len) :
        clamp(p.view_top, 1, max_view_top(len, p.view_rows))
    return p
end

max_view_top(len::Integer, visible::Integer) = max(1, len - visible + 1)

"""
    attach!(pane, term)

Show the screen of `term`. Its row count must equal `pane.screen_rows`. Any selection is cleared,
since it refers to the previous terminal.
"""
function attach!(p::Pane, term::Terminal)
    term.rows == p.screen_rows ||
        error("the terminal has $(term.rows) rows but the pane shows $(p.screen_rows)")
    p.term = term
    p.selection = nothing
    p.follow && (p.top = follow_top(p))
    return refill!(p)
end

"""
    refresh!(pane)

Refill the rows after the log or the screen has changed. Does nothing unless the pane is following;
a pane that the user has scrolled up keeps its rows.
"""
function refresh!(p::Pane)
    sync_selection!(p)
    p.follow || return p
    p.top = follow_top(p)
    return refill!(p)
end

"""
    set_screen_rows!(pane, rows)

Change the number of screen rows shown, and refill. The terminal must already have `rows` rows.
A change of the row count clears the selection.
"""
function set_screen_rows!(p::Pane, screen_rows::Integer)
    r = check_rows(screen_rows)
    r == p.screen_rows && return p
    p.screen_rows = r
    p.selection = nothing
    p.top = p.follow ? follow_top(p) : clamp_top(p, p.top)
    return refill!(p)
end

"""
    set_view_rows!(pane, rows)

Set the number of rows the view shows, which the scrollbar, the page jumps and the follow rule use.
`rows` must be at least 1, else an `ArgumentError` is thrown. A value above `MAX_VIEW_ROWS` is clamped
to `MAX_VIEW_ROWS`, so that the thumb and the pages then treat the view as that many rows, even when
the pane shows more. The matrix is not refilled.
"""
function set_view_rows!(p::Pane, rows::Integer)
    rows >= 1 || throw(ArgumentError("the view must show at least 1 row, got $rows"))
    p.view_rows = min(Int(rows), MAX_VIEW_ROWS)
    sync_view!(p)
    return p
end

"""
    resume_following!(pane)

Make the pane follow the bottom again and refill, for example after the user has typed into a pane
that they had scrolled up.
"""
function resume_following!(p::Pane)
    p.follow = true
    return refresh!(p)
end

"""
    user_scrolled!(pane, first, count, at_end) -> Int

Update after the user scrolls. `first` is the matrix row at the top of the view, `count` the number
of rows in the view, and `at_end` whether the view shows the last row of the matrix. The matrix is
refilled, centred on the view, when the view comes within `MARGIN_ROWS` of an edge. The pane
follows the bottom only if `at_end` holds and the matrix ends at the end of the sequence.

Returns the change in `top`. The view must move by this many rows to show the same entries. A
`count` above the number of rows in the matrix is taken as that number, since the view may be taller
than the matrix.
"""
function user_scrolled!(p::Pane, first::Integer, count::Integer, at_end::Bool)
    N = size(p.rows, 1)
    (1 <= first <= N && count >= 1) ||
        throw(ArgumentError("view row $first with count $count is outside the $N rows of the pane"))
    count = min(Int(count), N)
    old = p.top
    p.follow = false
    p.view_top = clamp(p.top + first - 1, 1, max_view_top(seq_length(p), p.view_rows))
    if first <= MARGIN_ROWS || first + count - 1 > N - MARGIN_ROWS
        a = p.top + first - 1
        newtop = clamp_top(p, a - fld(N - count, 2))
        if newtop != p.top
            p.top = newtop
            refill!(p)
        end
    end
    p.follow = at_end && p.top == follow_top(p)
    sync_view!(p)
    return p.top - old
end

"""
    follow_row(pane) -> Int

Matrix row (1-based) that a following pane keeps in view, when that is the cursor row above the end
of the sequence. Returns 0 when the pane is not following, or when the view should show the end of
the sequence.
"""
function follow_row(p::Pane)
    p.follow || return 0
    shown = shown_rows(p)
    s = follow_position(p, shown, cursor_position(p, shown))
    s === nothing && return 0
    slot = s - p.top + 1
    1 <= slot <= size(p.rows, 1) ||
        error("the cursor row $s is outside the matrix rows $(p.top):$(p.top + size(p.rows, 1) - 1)")
    return slot
end

"""
    cursor_slot(pane) -> Union{Nothing, Tuple{Int, Int}}

Matrix row and column (both 1-based) of the cursor, or `nothing` if the cursor is hidden or outside
the rows shown.
"""
function cursor_slot(p::Pane)
    shown = shown_rows(p)
    cursor = cursor_position(p, shown)
    cursor === nothing && return nothing
    slot = length(p.log) + cursor[1] - p.top + 1
    1 <= slot <= size(p.rows, 1) || return nothing
    return (slot, cursor[2])
end

# Scrollbar and jumps
#
# The functions below take the sequence length as an argument, so that the mapping can be tested at
# lengths far larger than a test can build. Positions are sequence positions of the view top.

# Round half up, so that a tie maps the same way at every length.
round_half_up(x::Real) = floor(Int, x + 0.5)

function check_fraction(f::Real)
    isfinite(f) && 0 <= f <= 1 || throw(ArgumentError("a scrollbar fraction must be in [0, 1], got $f"))
    return Float64(f)
end

"""
    top_for_fraction(f, len, visible) -> Int

The sequence position at the top of the view for scrollbar fraction `f` in [0, 1], for a sequence of
`len` rows of which `visible` are shown: `1 + round(f * (len - visible))`, with halves rounded up.
When the sequence is no longer than the view, this is 1.
"""
function top_for_fraction(f::Real, len::Integer, visible::Integer)
    f = check_fraction(f)
    len <= visible && return 1
    return 1 + round_half_up(f * (len - visible))
end

"""
    thumb_position(top, len, visible) -> Float64

The scrollbar fraction of the view top `top`, in [0, 1]. It is the inverse of `top_for_fraction`
up to rounding: 0 for the first row and 1 for the last position of the view. Zero when the sequence
is no longer than the view.
"""
function thumb_position(top::Integer, len::Integer, visible::Integer)
    len <= visible && return 0.0
    return (clamp(top, 1, max_view_top(len, visible)) - 1) / (len - visible)
end

"""
    thumb_size(len, visible) -> Float64

The fraction of the sequence that the view shows, in (0, 1]. One when the sequence is no longer than
the view.
"""
thumb_size(len::Integer, visible::Integer) = len <= visible ? 1.0 : visible / len

"""
    page_top(top, dir, len, visible) -> Int

The view top after one page in direction `dir` (-1 up, 1 down) from `top`. A page is `visible - 1`
rows, or one row when only one is visible, so that a page keeps one row in common with the view it
replaces. The result is limited to the sequence.
"""
function page_top(top::Integer, dir::Integer, len::Integer, visible::Integer)
    abs(dir) == 1 || throw(ArgumentError("dir must be -1 or 1, got $dir"))
    step = max(1, visible - 1)
    return clamp(top + dir * step, 1, max_view_top(len, visible))
end

# Shows the sequence from `v`, a sequence position for the view top. A view at the end of the
# sequence resumes following, and the view is then placed by the follow rule, so the result is 0.
# Otherwise the matrix is refilled around `v` when its top changes, and the result is the matrix row
# at the top of the view. Notifies at most once.
function show_view!(p::Pane, v::Integer)
    shown = shown_rows(p)
    len = length(p.log) + length(shown)
    last = max_view_top(len, p.view_rows)
    v = clamp(Int(v), 1, last)
    if v == last
        p.follow = true
        refresh!(p)
        return 0
    end
    p.follow = false
    p.view_top = v
    newtop = clamp_top(p, v - fld(size(p.rows, 1) - p.view_rows, 2))
    if newtop != p.top
        p.top = newtop
        refill!(p)
    end
    return v - p.top + 1
end

"""
    scroll_to_fraction!(pane, f) -> Int

Show the part of the sequence at scrollbar fraction `f` in [0, 1], as `top_for_fraction` gives it.
Returns the matrix row at the top of the view, or 0 when the view now follows the bottom. Fraction 1
resumes following. A fraction that gives the position already shown does not refill.
"""
function scroll_to_fraction!(p::Pane, f::Real)
    sync_view!(p)
    return show_view!(p, top_for_fraction(f, seq_length(p), p.view_rows))
end

"""
    page!(pane, dir) -> Int

Scroll one page up (`dir` = -1) or down (`dir` = 1), as `page_top` gives it. Returns as
`scroll_to_fraction!`.
"""
function page!(p::Pane, dir::Integer)
    sync_view!(p)
    return show_view!(p, page_top(p.view_top, dir, seq_length(p), p.view_rows))
end

"""
    scroll_to_top!(pane) -> Int

Show the first row of the sequence and stop following. Returns as `scroll_to_fraction!`.
"""
scroll_to_top!(p::Pane) = show_view!(p, 1)

"""
    scroll_to_bottom!(pane) -> Int

Show the end of the sequence and resume following. Returns as `scroll_to_fraction!`.
"""
function scroll_to_bottom!(p::Pane)
    sync_view!(p)
    return show_view!(p, max_view_top(seq_length(p), p.view_rows))
end

"""
    scrollbar_state(pane) -> Tuple{Float64, Float64}

The thumb position (see `thumb_position`) and size (see `thumb_size`) of the scrollbar.
"""
function scrollbar_state(p::Pane)
    len = seq_length(p)
    return thumb_position(p.view_top, len, p.view_rows), thumb_size(len, p.view_rows)
end

"""
    scroll_action(key, modifiers) -> Union{Nothing, Symbol}

The jump that a key press asks for, or `nothing` for any other key. Shift+PageUp and Shift+PageDown
give `:page_up` and `:page_down`; Ctrl+Home and Ctrl+End give `:top` and `:bottom`. The modifiers
must be exactly Shift or exactly Ctrl, ignoring the keypad and group bits.
"""
function scroll_action(key::Integer, modifiers::Integer)
    m = Int(modifiers) & (MOD_SHIFT | MOD_CTRL | MOD_ALT | MOD_META)
    k = Int(key)
    if m == MOD_SHIFT
        k == KEY_PAGEUP && return :page_up
        k == KEY_PAGEDOWN && return :page_down
    elseif m == MOD_CTRL
        k == KEY_HOME && return :top
        k == KEY_END && return :bottom
    end
    return nothing
end

"""
    scroll_action!(pane, action) -> Int

Carry out an action from `scroll_action`. Returns as `scroll_to_fraction!`.
"""
function scroll_action!(p::Pane, action::Symbol)
    action === :page_up && return page!(p, -1)
    action === :page_down && return page!(p, 1)
    action === :top && return scroll_to_top!(p)
    action === :bottom && return scroll_to_bottom!(p)
    throw(ArgumentError("unknown scroll action $action"))
end

# Selection
#
# A position is a sequence position and a 1-based column in that row. For a log entry the column is
# a character of its text. For a screen row it is a cell. Both ends are inclusive.

ordered_bounds(sel::Selection) =
    (sel.anchor.seq, sel.anchor.col) <= (sel.focus.seq, sel.focus.col) ? (sel.anchor, sel.focus) :
    (sel.focus, sel.anchor)

# Length of a log entry as a row: its characters, or none for a restart entry.
entry_length(e::LogEntry) = e.kind === :restart ? 0 : length(e.text)

# Characters of the row at sequence position `seq`, and whether it continues the row before it. A
# restart entry has no characters: it is shown as a separator and is not copied.
function row_info(p::Pane, seq::Integer, shown::Vector{ShownRow})
    n = length(p.log)
    if seq <= n
        e = window(p.log, seq:seq)[1]
        return (e.kind === :restart ? Char[] : collect(e.text)), false
    end
    r = shown[seq - n]
    return Char[c.char for c in r.cells], r.joins
end

row_joins(p::Pane, seq::Integer, shown::Vector{ShownRow}) = seq > length(p.log) && shown[seq - length(p.log)].joins

# The columns of row `seq` (of length `len`) that the selection covers. Empty when the row is not
# in the selection.
selection_range(::Nothing, seq::Integer, len::Integer) = 1:0

function selection_range(sel::Selection, seq::Integer, len::Integer)
    a, b = ordered_bounds(sel)
    (seq < a.seq || seq > b.seq) && return 1:0
    lo = seq == a.seq ? a.col : 1
    hi = min(seq == b.seq ? b.col : len, len)
    return lo:hi
end

# Maps a position made against the sequence at `n0` log entries, with `consumed` rows of the old
# shown rows having been appended to the log as `entries`, onto the sequence at `n` entries. Rows
# that were consumed keep their text, which is now in one log entry; the rows that remain shown keep
# their order after the log.
function moved_position(pos::SelPos, n0::Int, n::Int, entries, consumed::Int, cols::Int)
    pos.seq <= n0 && return pos
    j = pos.seq - n0
    if j <= consumed
        before = 0
        for (k, e) in enumerate(entries)
            if j <= before + e.nrows
                return SelPos(n0 + k, (j - before - 1) * cols + pos.col)
            end
            before += e.nrows
        end
    end
    return SelPos(n + j - consumed, pos.col)
end

# Brings the selection up to date with the log and the screen. Lines that have left the screen since
# the last call are appended to the log, and their screen rows were the first shown rows, so the
# positions after them are re-based by the rows consumed. The selection is dropped when the terminal
# is on the alternate screen or its width has changed, since the rows it refers to no longer exist.
# Positions past the end of the sequence are moved to its last row.
function sync_selection!(p::Pane, shown::Vector{ShownRow})
    sel = p.selection
    sel === nothing && return nothing
    t = p.term
    if t === nothing || is_alternate(t) || t.cols != sel.cols
        p.selection = nothing
        return nothing
    end
    n0 = sel.log_length
    n = length(p.log)
    if n > n0
        entries = window(p.log, (n0 + 1):n)
        consumed = sum(e.nrows for e in entries; init = 0)
        sel.anchor = moved_position(sel.anchor, n0, n, entries, consumed, sel.cols)
        sel.focus = moved_position(sel.focus, n0, n, entries, consumed, sel.cols)
    end
    total = n + length(shown)
    if total == 0
        p.selection = nothing
        return nothing
    end
    sel.anchor = SelPos(clamp(sel.anchor.seq, 1, total), sel.anchor.col)
    sel.focus = SelPos(clamp(sel.focus.seq, 1, total), sel.focus.col)
    sel.log_length = n
    sel.shown_count = length(shown)
    return nothing
end

sync_selection!(p::Pane) = p.selection === nothing ? nothing : sync_selection!(p, shown_rows(p))

# Sequence position for matrix row `slot` and column `col`. The row is clamped to the matrix and the
# sequence, so a drag past either edge gives the first or last row.
function slot_position(p::Pane, slot::Integer, col::Integer, shown::Vector{ShownRow})
    N = size(p.rows, 1)
    total = length(p.log) + length(shown)
    seq = clamp(p.top + clamp(Int(slot), 1, N) - 1, 1, total)
    return SelPos(seq, max(Int(col), 1))
end

function new_selection(p::Pane, a::SelPos, b::SelPos, dragging::Bool, shown::Vector{ShownRow};
        span::Bool = false)
    return Selection(a, b, dragging, length(p.log), length(shown), p.term.cols, span, false)
end

"""
    is_word_char(c) -> Bool

Whether `c` is part of a word for double-click selection: a letter (including non-ASCII letters), an
ASCII digit, `_`, `!` or `?`.
"""
is_word_char(c::Char) = isletter(c) || isdigit(c) || c in ('_', '!', '?')

"""
    word_range(chars, col) -> UnitRange{Int}

The run of word characters (see `is_word_char`) in `chars` that contains index `col`. Empty when
`col` is not a word character.
"""
function word_range(chars::AbstractVector{Char}, col::Integer)
    col in eachindex(chars) || return 1:0
    is_word_char(chars[col]) || return 1:0
    lo = col
    while lo > firstindex(chars) && is_word_char(chars[lo - 1])
        lo -= 1
    end
    hi = col
    while hi < lastindex(chars) && is_word_char(chars[hi + 1])
        hi += 1
    end
    return lo:hi
end

"""
    select_start!(pane, slot, col)

Start a selection at matrix row `slot` and column `col`, and drag it with `select_extend!`. Rows
outside the matrix are clamped to its first or last row.
"""
function select_start!(p::Pane, slot::Integer, col::Integer)
    shown = shown_rows(p)
    if length(p.log) + length(shown) == 0
        p.selection = nothing
        return refill!(p)
    end
    pos = slot_position(p, slot, col, shown)
    p.selection = new_selection(p, pos, pos, true, shown)
    return refill!(p)
end

"""
    select_extend!(pane, slot, col)

Move the focus of the selection being dragged. Does nothing if the selection was cleared during the
drag, by a key press or a change of screen. Throws if the selection is not being dragged.
"""
function select_extend!(p::Pane, slot::Integer, col::Integer)
    shown = shown_rows(p)
    sync_selection!(p, shown)
    sel = p.selection
    sel === nothing && return p
    sel.dragging || error("select_extend! called without a drag in progress")
    sel.focus = slot_position(p, slot, col, shown)
    return refill!(p)
end

"""
    select_extend_start!(pane, slot, col)

Start a drag for a Shift-press, which moves the active end of the selection (its focus) to `slot` and
`col`, and keeps the anchor. Continue the drag with `select_extend!` and end it with `select_end!`.
The selection is extended by character cell, whatever click made it. After a word or line selection,
the anchor is taken from the span: its start when the position is at or after the start, and its end
when the position is before the start. So the edge of the span that is farther from the press stays
fixed, and a click inside the span keeps the start as the anchor. With no selection, this is
`select_start!`, a plain press.
"""
function select_extend_start!(p::Pane, slot::Integer, col::Integer)
    shown = shown_rows(p)
    sync_selection!(p, shown)
    sel = p.selection
    sel === nothing && return select_start!(p, slot, col)
    pos = slot_position(p, slot, col, shown)
    if sel.span
        a, b = ordered_bounds(sel)
        sel.anchor = (pos.seq, pos.col) < (a.seq, a.col) ? b : a
    end
    sel.focus = pos
    sel.dragging = true
    sel.span = false
    sel.extended = true
    return refill!(p)
end

"""
    select_end!(pane)

End a drag. A drag that did not move from its starting position is a click, and clears the selection.
A Shift-press that did not move keeps its selection, since the anchor is then the cell that was clicked.
"""
function select_end!(p::Pane)
    sync_selection!(p)
    sel = p.selection
    sel === nothing && return p
    sel.dragging || return p
    sel.dragging = false
    if sel.anchor == sel.focus && !sel.extended
        p.selection = nothing
        return refill!(p)
    end
    return p
end

"""
    select_word!(pane, slot, col)

Select the word under matrix row `slot` and column `col`, as `word_range` defines it. Clears the
selection when the cell is not part of a word.
"""
function select_word!(p::Pane, slot::Integer, col::Integer)
    shown = shown_rows(p)
    if length(p.log) + length(shown) == 0
        p.selection = nothing
        return refill!(p)
    end
    pos = slot_position(p, slot, col, shown)
    chars, _ = row_info(p, pos.seq, shown)
    r = word_range(chars, pos.col)
    p.selection = isempty(r) ? nothing :
        new_selection(p, SelPos(pos.seq, first(r)), SelPos(pos.seq, last(r)), false, shown; span = true)
    return refill!(p)
end

"""
    select_line!(pane, slot)

Select the logical line under matrix row `slot`: a row and the screen rows that continue it. Each
row is selected to its full width.
"""
function select_line!(p::Pane, slot::Integer)
    shown = shown_rows(p)
    if length(p.log) + length(shown) == 0
        p.selection = nothing
        return refill!(p)
    end
    pos = slot_position(p, slot, 1, shown)
    lo = pos.seq
    while lo > 1 && row_joins(p, lo, shown)
        lo -= 1
    end
    hi = pos.seq
    total = length(p.log) + length(shown)
    while hi < total && row_joins(p, hi + 1, shown)
        hi += 1
    end
    chars, _ = row_info(p, hi, shown)
    p.selection = new_selection(p, SelPos(lo, 1), SelPos(hi, length(chars)), false, shown; span = true)
    return refill!(p)
end

"""
    clear_selection!(pane)

Remove the selection and refill, if there is one.
"""
function clear_selection!(p::Pane)
    p.selection === nothing && return p
    p.selection = nothing
    return refill!(p)
end

"""
    selected_text(pane) -> Union{Nothing, String}

The text of the selection, or `nothing` when there is no selection. Rows are joined by newlines,
except that a screen row which continues the row before it is joined without one. Trailing blanks
are removed from each row that ends a line. Session separators are not copied.
"""
function selected_text(p::Pane)
    shown = shown_rows(p)
    sync_selection!(p, shown)
    sel = p.selection
    sel === nothing && return nothing
    a, b = ordered_bounds(sel)
    io = IOBuffer()
    for seq in a.seq:b.seq
        chars, _ = row_info(p, seq, shown)
        seq > a.seq && !row_joins(p, seq, shown) && print(io, '\n')
        from = seq == a.seq ? a.col : 1
        to = min(seq == b.seq ? b.col : length(chars), length(chars))
        seg = from <= to ? chars[from:to] : Char[]
        if !(seq < b.seq && row_joins(p, seq + 1, shown))
            k = findlast(!=(' '), seg)
            seg = k === nothing ? Char[] : seg[1:k]
        end
        print(io, join(seg))
    end
    return String(take!(io))
end

# Colours and styles

function hex_colour(rgb::NTuple{3, Integer})
    return string('#', join((lpad(string(c, base = 16), 2, '0') for c in rgb)))
end

"""
    palette_hex(i) -> String

The `#rrggbb` colour of xterm palette index `i` in 0:255.
"""
function palette_hex(i::Integer)
    0 <= i <= 255 || throw(ArgumentError("palette index must be in 0:255, got $i"))
    i < 16 && return PALETTE16[i + 1]
    if i < 232
        k = i - 16
        return hex_colour((CUBE_LEVELS[k ÷ 36 + 1], CUBE_LEVELS[(k % 36) ÷ 6 + 1], CUBE_LEVELS[k % 6 + 1]))
    end
    v = 8 + 10 * (i - 232)
    return hex_colour((v, v, v))
end

# A colour code from VTParse: a palette index, or RGB_FLAG plus 0xRRGGBB.
function colour_hex(c::Integer)
    c = Int(c)
    c & RGB_FLAG == 0 && return palette_hex(c)
    return hex_colour(((c >> 16) & 0xff, (c >> 8) & 0xff, c & 0xff))
end

# Halfway between a colour and the background, for the dim attribute.
function dim_colour(s::String)
    rgb = (parse(Int, s[2:3], base = 16), parse(Int, s[4:5], base = 16), parse(Int, s[6:7], base = 16))
    return hex_colour(Tuple((a + b) ÷ 2 for (a, b) in zip(rgb, DEFAULT_BG_RGB)))
end

"""
    style_css(style) -> String

CSS declarations for a `VTParse.Style`. The default style gives an empty string, so that its text
inherits the pane's colours.
"""
function style_css(s::Style)
    s == DEFAULT_STYLE && return ""
    fg = s.fg == -1 ? DEFAULT_FG : colour_hex(s.fg)
    bg = s.bg == -1 ? nothing : colour_hex(s.bg)
    attrs = s.attrs
    if attrs & ATTR_REVERSE != 0
        fg, bg = (bg === nothing ? DEFAULT_BG : bg), fg
    end
    attrs & ATTR_DIM != 0 && (fg = dim_colour(fg))
    parts = String["color:$fg"]
    bg === nothing || push!(parts, "background-color:$bg")
    attrs & ATTR_BOLD != 0 && push!(parts, "font-weight:bold")
    attrs & ATTR_ITALIC != 0 && push!(parts, "font-style:italic")
    decorations = String[]
    attrs & ATTR_UNDERLINE != 0 && push!(decorations, "underline")
    attrs & ATTR_STRIKE != 0 && push!(decorations, "line-through")
    isempty(decorations) || push!(parts, "text-decoration:" * join(decorations, " "))
    return join(parts, ";")
end

# HTML

"""
    html_escape(text) -> String

Escape `text` for use as rich text. Spaces and control characters become `&nbsp;`, so runs of
spaces keep their width.
"""
function html_escape(s::AbstractString)
    io = IOBuffer()
    for c in s
        if c == '&'
            print(io, "&amp;")
        elseif c == '<'
            print(io, "&lt;")
        elseif c == '>'
            print(io, "&gt;")
        elseif c == '"'
            print(io, "&quot;")
        elseif c == ' ' || c < ' ' || c == '\x7f'
            print(io, "&nbsp;")
        else
            print(io, c)
        end
    end
    return String(take!(io))
end

function span_html(text::AbstractString, css::AbstractString)
    isempty(text) && return ""
    body = html_escape(text)
    isempty(css) && return body
    return string("<span style=\"", css, "\">", body, "</span>")
end

# Rich text for characters with their styles. Runs of equal style become one span. The cursor cell
# (`cursor_col`) and the selected cells (`selected`, a range of indices) are drawn with their own
# colours. Trailing blank cells are left out unless they are the cursor or selected.
function runs_html(chars::AbstractVector{Char}, styles::AbstractVector{Style};
        cursor_col::Union{Nothing, Integer} = nothing, selected::AbstractUnitRange{<:Integer} = 1:0)
    cur = cursor_col === nothing ? 0 : Int(cursor_col)
    last = 0
    for c in eachindex(chars)
        (chars[c] != ' ' || styles[c] != DEFAULT_STYLE || c == cur || c in selected) && (last = c)
    end
    io = IOBuffer()
    i = firstindex(chars)
    while i <= last
        style = styles[i]
        sel = i in selected
        j = i
        if i != cur
            while j < last && j + 1 != cur && styles[j + 1] == style && (j + 1 in selected) == sel
                j += 1
            end
        end
        text = String(chars[i:j])
        css = i == cur ? CURSOR_CSS : sel ? SELECTION_CSS : style_css(style)
        print(io, span_html(text, css))
        i = j + 1
    end
    return String(take!(io))
end

"""
    line_html(text, spans; selected = 1:0) -> String

Rich text for a log line. `spans` are the `(byte range, style)` runs of `VTParse.LogLine`, and each
range indexes `text`. `selected` is the range of characters to draw as selected.
"""
function line_html(text::AbstractString, spans; selected::AbstractUnitRange{<:Integer} = 1:0)
    chars = Char[]
    styles = Style[]
    for (r, s) in spans, c in text[r]
        push!(chars, c)
        push!(styles, s)
    end
    return runs_html(chars, styles; selected)
end

# Separator text for a restart entry, with the previous session's end when it is known.
restart_label(e::LogEntry) = isempty(e.text) ? "--- session $(e.session) ---" :
    "--- session $(e.session) started; previous $(e.text) ---"

entry_html(e::LogEntry; selected::AbstractUnitRange{<:Integer} = 1:0) =
    e.kind === :restart ? span_html(restart_label(e), RESTART_CSS) :
    line_html(e.text, e.spans; selected)

"""
    screen_html(term, row; cursor_col = nothing) -> String

Rich text for screen row `row` of `term`, as `cells_html`.
"""
screen_html(t::Terminal, r::Integer; cursor_col::Union{Nothing, Integer} = nothing) =
    cells_html(screen_row(t, r); cursor_col)

"""
    cells_html(cells; cursor_col = nothing, selected = 1:0) -> String

Rich text for a row of cells, with trailing blank cells removed. If `cursor_col` is given, that cell
is drawn as the cursor, with its colours inverted. The cells in the range `selected` are drawn as
selected.
"""
function cells_html(cells::Vector{Cell}; cursor_col::Union{Nothing, Integer} = nothing,
        selected::AbstractUnitRange{<:Integer} = 1:0)
    return runs_html(Char[c.char for c in cells], Style[c.style for c in cells]; cursor_col, selected)
end

end # module PaneModel
