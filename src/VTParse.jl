# Terminal screen model: turns a VT/ANSI byte stream into logical lines.
#
# The parser is a byte-wise state machine, so input may be split at any byte. The screen is a grid
# of cells, each with a style. A logical line is one or more screen rows joined by automatic wrapping.
#
# A logical line is emitted once, as a `LogLine`, only when its text leaves the screen or the
# session ends: when the last row of the line leaves the top of a scroll region (rows that leave
# earlier are held until then), when `flush!` is called, or when the screen is cleared (ED 2 and
# RIS), which emits the screen's lines first. Line feeds, cursor motion, erasing and editing do not
# emit anything, so a line on screen can still be edited, and the screen shows the edit. Emitted
# rows are marked as done: they are not shown from the screen, and a write into one is counted as a
# rewrite by `counters`.
#
# Span indices in `LogLine` are byte ranges into `text`.
#
# Not modelled: wide characters (text is correct, cursor columns and wrapping are not), character
# sets, reflow of finished lines on resize, and the contents of the alternate screen (nothing is
# emitted while it is active; the main screen is restored when the process ends).
module VTParse

export Terminal, Style, Cell, LogLine, feed!, flush!, take_lines!, resize_screen!, live_line,
    counters, is_alternate, row_finished, row_continues, bracketed_paste, application_cursor, screen_lines,
    screen_cell, screen_row, pending_rows, cursor_pos, take_replies!,
    DEFAULT_STYLE, ATTR_BOLD, ATTR_DIM, ATTR_ITALIC, ATTR_UNDERLINE, ATTR_BLINK, ATTR_REVERSE,
    ATTR_STRIKE

const ATTR_BOLD = 0x01
const ATTR_DIM = 0x02
const ATTR_ITALIC = 0x04
const ATTR_UNDERLINE = 0x08
const ATTR_BLINK = 0x10
const ATTR_REVERSE = 0x20
const ATTR_STRIKE = 0x40

# Colour codes: -1 is the default colour; 0:255 is an indexed colour; RGB_FLAG | 0xRRGGBB is a
# truecolour.
const RGB_FLAG = 1 << 24

# Rows kept above the screen. The lines that leave the screen are kept by the caller, so this only
# bounds the parser.
const SCROLLBACK_ROWS = 100

# Numeric CSI parameters saturate here, so a long digit run cannot overflow.
const MAX_PARAM = 65535

struct Style
    fg::Int32
    bg::Int32
    attrs::UInt8
end
const DEFAULT_STYLE = Style(-1, -1, 0x00)

struct Cell
    char::Char
    style::Style
end
const BLANK_CELL = Cell(' ', DEFAULT_STYLE)

"""
    LogLine

A logical line. `text` has trailing default-style spaces removed. `spans` are
`(byte range, style)` runs that cover `text` in order. Each range starts at the first byte of the
run's first character and ends at the first byte of its last character, so `text[range]` is the
run's text.
`t_ns` is the time passed to `feed!` for the bytes that made the line leave the screen, or the time
passed to `flush!` for a line emitted then. `nrows` is the
number of screen rows the line occupied.
"""
struct LogLine
    text::String
    spans::Vector{Tuple{UnitRange{Int}, Style}}
    t_ns::UInt64
    nrows::Int
end

Base.:(==)(a::LogLine, b::LogLine) = a.text == b.text && a.spans == b.spans && a.t_ns == b.t_ns && a.nrows == b.nrows

# Main screen while the alternate screen is active.
mutable struct SavedScreen
    screen::Vector{Vector{Cell}}
    wrapped::Vector{Bool}
    done::Vector{Bool}
    row::Int
    col::Int
    pending_wrap::Bool
    top::Int
    bottom::Int
    pending::Vector{Vector{Cell}}
end

"""
    Terminal(rows = 24, cols = 80)

Screen model with a parser state. Feed it bytes with `feed!`, take the lines that have left the
screen with `take_lines!`, and read the cursor's logical line with `live_line`.
"""
mutable struct Terminal
    rows::Int
    cols::Int
    screen::Vector{Vector{Cell}}
    wrapped::Vector{Bool}            # the row continues the logical line of the row above
    done::Vector{Bool}               # the row's text is in the log; see `emit_screen!`
    row::Int
    col::Int
    pending_wrap::Bool
    top::Int                         # scroll region
    bottom::Int
    style::Style
    saved_row::Int
    saved_col::Int
    saved_style::Style
    cursor_visible::Bool
    bracketed_paste::Bool
    application_cursor::Bool         # DECCKM: unmodified arrows, Home and End send SS3
    pending::Vector{Vector{Cell}}    # rows that left the top of the scroll region before their line ended; they precede row `top`
    scrollback::Vector{Vector{Cell}}
    main::Union{Nothing, SavedScreen}
    log::Vector{LogLine}
    ignored::Dict{String, Int}
    rewrites::Int                    # writes that changed an emitted row
    discarded::Int                   # text removed from the screen without being emitted
    answered::Dict{String, Int}      # queries answered, by name; see `answer_query!`
    outbox::Vector{UInt8}            # replies to queries, not yet taken by `take_replies!`
    # parser state
    state::Symbol
    groups::Vector{Vector{Int}}
    cur::Int
    intermediate::UInt8
    private::UInt8
    utf_val::UInt32
    utf_need::Int
    utf_have::Int
    now_ns::UInt64
end

function Terminal(rows::Integer = 24, cols::Integer = 80)
    r, c = Int(rows), Int(cols)
    (r >= 1 && c >= 1) || throw(ArgumentError("terminal size must be at least 1 by 1, got $rows by $cols"))
    screen = [fill(BLANK_CELL, c) for _ in 1:r]
    return Terminal(
        r, c, screen, fill(false, r), fill(false, r),
        1, 1, false, 1, r, DEFAULT_STYLE, 1, 1, DEFAULT_STYLE, true, false, false,
        Vector{Cell}[], Vector{Cell}[], nothing, LogLine[], Dict{String, Int}(), 0, 0,
        Dict{String, Int}(), UInt8[],
        :ground, [Int[]], -1, 0x00, 0x00, 0x00000000, 0, 0, time_ns(),
    )
end

ignore!(t::Terminal, key::AbstractString) = (t.ignored[key] = get(t.ignored, key, 0) + 1; nothing)

is_alternate(t::Terminal) = t.main !== nothing

"""
    feed!(t, bytes, t_ns = time_ns())

Process `bytes`. Lines that leave the screen with these bytes are appended to `t.log` with
timestamp `t_ns`.
Sequences and characters may be split across calls.
"""
function feed!(t::Terminal, bytes::AbstractVector{UInt8}, t_ns::UInt64 = time_ns())
    t.now_ns = t_ns
    for b in bytes
        step!(t, b)
    end
    return t
end

function step!(t::Terminal, b::UInt8)
    st = t.state
    if st === :ground
        if b == 0x1b
            t.state = :esc
        elseif b < 0x20 || b == 0x7f
            control!(t, b)
        elseif b < 0x80
            put_char!(t, Char(b))
        else
            start_utf8!(t, b)
        end
    elseif st === :utf8
        if b & 0xc0 == 0x80
            t.utf_val = (t.utf_val << 6) | UInt32(b & 0x3f)
            t.utf_have += 1
            if t.utf_have == t.utf_need
                c = isvalid(Char, t.utf_val) ? Char(t.utf_val) : '�'
                t.state = :ground
                put_char!(t, c)
            end
        else
            t.state = :ground
            put_char!(t, '�')
            step!(t, b)
        end
    elseif st === :esc
        if b == UInt8('[')
            t.state = :csi
            t.groups = [Int[]]
            t.cur = -1
            t.intermediate = 0x00
            t.private = 0x00
        elseif b == UInt8(']')
            ignore!(t, "OSC")
            t.state = :osc
        elseif b == UInt8('P') || b == UInt8('X') || b == UInt8('^') || b == UInt8('_')
            ignore!(t, "string sequence")
            t.state = :str
        elseif 0x20 <= b <= 0x2f
            t.state = :esc_int
        elseif b == 0x18 || b == 0x1a
            t.state = :ground
        elseif b < 0x20
            b == 0x1b || control!(t, b)
        else
            t.state = :ground
            esc_final!(t, b)
        end
    elseif st === :esc_int
        # Final byte of a designation such as ESC ( B. Character sets are not modelled.
        t.state = :ground
        ignore!(t, "ESC designation")
    elseif st === :csi
        csi_byte!(t, b)
    elseif st === :osc
        if b == 0x07
            t.state = :ground
        elseif b == 0x1b
            t.state = :str_esc
        end
    elseif st === :str
        if b == 0x1b
            t.state = :str_esc
        end
    elseif st === :str_esc
        if b == UInt8('\\')
            t.state = :ground
        else
            t.state = :esc
            step!(t, b)
        end
    else
        error("VTParse: unknown parser state $st")
    end
    return nothing
end

function start_utf8!(t::Terminal, b::UInt8)
    if 0xc2 <= b <= 0xdf
        t.utf_need, t.utf_val = 1, UInt32(b & 0x1f)
    elseif 0xe0 <= b <= 0xef
        t.utf_need, t.utf_val = 2, UInt32(b & 0x0f)
    elseif 0xf0 <= b <= 0xf4
        t.utf_need, t.utf_val = 3, UInt32(b & 0x07)
    else
        put_char!(t, '�')
        return nothing
    end
    t.utf_have = 0
    t.state = :utf8
    return nothing
end

function esc_final!(t::Terminal, b::UInt8)
    if b == UInt8('7')
        save_cursor!(t)
    elseif b == UInt8('8')
        restore_cursor!(t)
    elseif b == UInt8('D')
        line_feed!(t)
    elseif b == UInt8('E')
        t.col = 1
        line_feed!(t)
    elseif b == UInt8('M')
        reverse_index!(t)
    elseif b == UInt8('c')
        reset!(t)
    elseif b == UInt8('=') || b == UInt8('>') || b == UInt8('\\')
        # Keypad modes and string terminator: no screen effect.
    else
        ignore!(t, "ESC " * string(Char(b)))
    end
    return nothing
end

function csi_byte!(t::Terminal, b::UInt8)
    if 0x30 <= b <= 0x39
        t.cur = min((t.cur < 0 ? 0 : t.cur) * 10 + (b - 0x30), MAX_PARAM)
    elseif b == UInt8(';')
        commit_param!(t)
        push!(t.groups, Int[])
    elseif b == UInt8(':')
        commit_param!(t)
    elseif 0x3c <= b <= 0x3f
        t.private = b
    elseif 0x20 <= b <= 0x2f
        t.intermediate = b
    elseif 0x40 <= b <= 0x7e
        commit_param!(t)
        t.state = :ground
        csi_dispatch!(t, b)
    elseif b == 0x1b
        # ESC starts a new sequence and cancels this one.
        t.state = :esc
    elseif b == 0x18 || b == 0x1a
        t.state = :ground
    elseif b < 0x20
        control!(t, b)
    else
        t.state = :ground
    end
    return nothing
end

function commit_param!(t::Terminal)
    push!(t.groups[end], t.cur)
    t.cur = -1
    return nothing
end

# First sub-parameter of group `i`, or `default` when the group is absent or empty.
function param(t::Terminal, i::Int, default::Int)
    i <= length(t.groups) || return default
    g = t.groups[i]
    (isempty(g) || g[1] < 0) && return default
    return g[1]
end

# Count or position argument: an explicit 0 also means the default, so CSI 0 B moves down one row.
function arg(t::Terminal, i::Int, default::Int)
    v = param(t, i, default)
    return v == 0 ? default : v
end

function csi_dispatch!(t::Terminal, final::UInt8)
    answer_query!(t, final) && return nothing
    if t.private == UInt8('?')
        if final == UInt8('h') || final == UInt8('l')
            set = final == UInt8('h')
            for g in t.groups
                (isempty(g) || g[1] < 0) && continue
                private_mode!(t, g[1], set)
            end
        else
            ignore!(t, "CSI ? ... $(Char(final))")
        end
        return nothing
    elseif t.private != 0x00
        ignore!(t, "CSI $(Char(t.private)) ... $(Char(final))")
        return nothing
    elseif t.intermediate != 0x00
        ignore!(t, "CSI intermediate $(Char(final))")
        return nothing
    end
    n = arg(t, 1, 1)
    if final == UInt8('A')
        cursor_to!(t, t.row - n, t.col)
    elseif final == UInt8('B')
        cursor_to!(t, t.row + n, t.col)
    elseif final == UInt8('C')
        cursor_to!(t, t.row, t.col + n)
    elseif final == UInt8('D')
        cursor_to!(t, t.row, t.col - n)
    elseif final == UInt8('E')
        cursor_to!(t, t.row + n, 1)
    elseif final == UInt8('F')
        cursor_to!(t, t.row - n, 1)
    elseif final == UInt8('G')
        cursor_to!(t, t.row, n)
    elseif final == UInt8('H') || final == UInt8('f')
        cursor_to!(t, arg(t, 1, 1), arg(t, 2, 1))
    elseif final == UInt8('d')
        cursor_to!(t, n, t.col)
    elseif final == UInt8('J')
        erase_display!(t, param(t, 1, 0))
    elseif final == UInt8('K')
        erase_line!(t, param(t, 1, 0))
    elseif final == UInt8('X')
        t.pending_wrap = false
        erase_cells!(t, t.row, t.col, min(t.cols, t.col + n - 1))
    elseif final == UInt8('@')
        insert_chars!(t, n)
    elseif final == UInt8('P')
        delete_chars!(t, n)
    elseif final == UInt8('L')
        insert_lines!(t, n)
    elseif final == UInt8('M')
        delete_lines!(t, n)
    elseif final == UInt8('S')
        scroll_up!(t, n)
    elseif final == UInt8('T')
        scroll_down!(t, n)
    elseif final == UInt8('r')
        top, bottom = arg(t, 1, 1), arg(t, 2, t.rows)
        if top < bottom && bottom <= t.rows
            emit_pending!(t)
            t.top, t.bottom = top, bottom
            cursor_to!(t, 1, 1)
        else
            ignore!(t, "CSI r with invalid margins")
        end
    elseif final == UInt8('m')
        sgr!(t)
    elseif final == UInt8('s')
        save_cursor!(t)
    elseif final == UInt8('u')
        restore_cursor!(t)
    else
        ignore!(t, "CSI $(Char(final))")
    end
    return nothing
end

# Terminal queries that the child waits on are answered (see `take_replies!` for the list). The
# reply reports the cursor as it is when the query is parsed, so it includes every byte before the query.
function answer_query!(t::Terminal, final::UInt8)
    length(t.groups) == 1 || return false
    p = param(t, 1, 0)
    if t.private == UInt8('?') && t.intermediate == 0x00 && final == UInt8('n') && p == 6
        answer!(t, "CSI ? 6 n", "\e[?$(t.row);$(t.col);1R")
    elseif t.private == 0x00 && t.intermediate == 0x00
        if final == UInt8('n') && p == 5
            answer!(t, "CSI 5 n", "\e[0n")
        elseif final == UInt8('n') && p == 6
            answer!(t, "CSI 6 n", "\e[$(t.row);$(t.col)R")
        elseif final == UInt8('c') && p == 0
            answer!(t, "CSI c", "\e[?1;2c")
        elseif final == UInt8('t') && p == 18
            answer!(t, "CSI 18 t", "\e[8;$(t.rows);$(t.cols)t")
        else
            return false
        end
    else
        return false
    end
    return true
end

function answer!(t::Terminal, key::String, reply::String)
    append!(t.outbox, codeunits(reply))
    t.answered[key] = get(t.answered, key, 0) + 1
    return nothing
end

# DEC private modes. Modes 1 (DECCKM), 25, 2004 and the alternate-screen modes 47, 1047 and 1049 are
# honoured; 1049 also saves and restores the cursor. Other modes are counted as ignored.
function private_mode!(t::Terminal, mode::Int, set::Bool)
    if mode == 25
        t.cursor_visible = set
    elseif mode == 1
        t.application_cursor = set
    elseif mode == 2004
        t.bracketed_paste = set
    elseif mode == 47 || mode == 1047 || mode == 1049
        if set
            enter_alternate!(t, mode == 1049)
        else
            leave_alternate!(t, mode == 1049)
        end
    else
        ignore!(t, "CSI ? $mode $(set ? 'h' : 'l')")
    end
    return nothing
end

function control!(t::Terminal, b::UInt8)
    if b == 0x08
        t.pending_wrap = false
        t.col = max(1, t.col - 1)
    elseif b == 0x09
        t.pending_wrap = false
        t.col = min(t.cols, ((t.col - 1) ÷ 8 + 1) * 8 + 1)
    elseif b == 0x0a || b == 0x0b || b == 0x0c
        line_feed!(t)
    elseif b == 0x0d
        t.pending_wrap = false
        t.col = 1
    elseif b == 0x07 || b == 0x0e || b == 0x0f || b == 0x7f
        # Bell, character-set shifts and delete: no screen effect.
    else
        ignore!(t, "C0 " * string(b))
    end
    return nothing
end

# ---- cursor -----------------------------------------------------------------

function cursor_to!(t::Terminal, row::Integer, col::Integer)
    t.row = clamp(Int(row), 1, t.rows)
    t.col = clamp(Int(col), 1, t.cols)
    t.pending_wrap = false
    return nothing
end

function save_cursor!(t::Terminal)
    t.saved_row, t.saved_col, t.saved_style = t.row, t.col, t.style
    return nothing
end

function restore_cursor!(t::Terminal)
    t.row = t.saved_row
    t.col = t.saved_col
    t.style = t.saved_style
    t.pending_wrap = false
    return nothing
end

# ---- logical lines ----------------------------------------------------------

# Screen row where the logical line containing row `r` begins. Rows above the scroll region top
# are not searched: their text is not part of the region's line model.
function line_start(t::Terminal, r::Int)
    lo = r >= t.top ? t.top : 1
    s = r
    while s > lo && t.wrapped[s]
        s -= 1
    end
    return s
end

# Last screen row of the logical line containing row `r`.
function line_end(t::Terminal, r::Int)
    e = r
    while e < t.rows && t.wrapped[e + 1]
        e += 1
    end
    return e
end

has_text(cells::Vector{Cell}) = any(c -> c.char != ' ', cells)

# Cells of the logical line occupying screen rows s:e. Pending rows are placed before row `top`.
function line_parts(t::Terminal, s::Int, e::Int)
    parts = Vector{Cell}[]
    for k in s:e
        if k == t.top && !isempty(t.pending)
            append!(parts, t.pending)
        end
        push!(parts, t.screen[k])
    end
    return parts
end

# Text and style runs of a logical line. Byte ranges index `text`.
function build_line(parts::Vector{Vector{Cell}}, t_ns::UInt64)
    chars = Char[]
    styles = Style[]
    for row in parts, cell in row
        push!(chars, cell.char)
        push!(styles, cell.style)
    end
    n = length(chars)
    while n > 0 && chars[n] == ' ' && styles[n] == DEFAULT_STYLE
        n -= 1
    end
    text = String(chars[1:n])
    spans = Tuple{UnitRange{Int}, Style}[]
    i = 1
    byte_start = 1
    while i <= n
        j = i
        while j < n && styles[j + 1] == styles[i]
            j += 1
        end
        nbytes = sum(ncodeunits(c) for c in view(chars, i:j))
        # The range ends at the first byte of the run's last character: Julia's `text[range]`
        # requires the end index to start a character.
        push!(spans, (byte_start:(byte_start + nbytes - ncodeunits(chars[j])), styles[i]))
        byte_start += nbytes
        i = j + 1
    end
    return LogLine(text, spans, t_ns, length(parts))
end

# Appends the logical line on screen rows s:e, with the pending rows that precede row `top` when
# they belong to it, and marks rows s:e as done.
function emit!(t::Terminal, s::Int, e::Int)
    parts = line_parts(t, s, e)
    for k in s:e
        t.done[k] = true
    end
    if s <= t.top <= e
        empty!(t.pending)
    end
    push!(t.log, build_line(parts, t.now_ns))
    return nothing
end

# Appends the logical lines on the screen down to the last row that holds text, in row order, and
# marks every row done. Blank rows above that row are blank lines of the output and are appended;
# blank rows below it are not output and are not appended. Pending rows are appended with the line
# that starts at row `top`. Called before the screen is cleared or the session ends, so that no text
# on screen is lost. Nothing is emitted while the alternate screen is active.
function emit_screen!(t::Terminal)
    is_alternate(t) && return nothing
    last = 0
    for r in 1:t.rows
        (!t.done[r] && has_text(t.screen[r])) && (last = r)
    end
    r = 1
    while r <= last
        if t.done[r]
            r += 1
            continue
        end
        e = line_end(t, r)
        emit!(t, r, e)
        r = e + 1
    end
    emit_pending!(t)
    fill!(t.done, true)
    return nothing
end

# A row `T` that has not been emitted is about to leave the top of the scroll region. Its text is
# kept as pending rows. When the logical line ends with this row, the pending rows are appended as
# one line. A blank row is a line of the output too, so it is appended like any other.
function leave_top!(t::Terminal, T::Int)
    continues = T < t.bottom && t.wrapped[T + 1]
    push!(t.pending, copy(t.screen[T]))
    continues && return nothing
    push!(t.log, build_line(t.pending, t.now_ns))
    empty!(t.pending)
    return nothing
end

# Appends the pending rows as a line, if there are any. They are valid only while the scroll region
# top is unchanged. The part of a line that is pending is appended as it is so far, and a later row
# of the same line is appended as a separate entry. Nothing is lost.
function emit_pending!(t::Terminal)
    isempty(t.pending) && return nothing
    push!(t.log, build_line(t.pending, t.now_ns))
    empty!(t.pending)
    return nothing
end

# Counts a row removed without being emitted, if it held text. Used for text removed from the
# middle or bottom of the screen, which cannot be appended without reordering the log.
function discard_row!(t::Terminal, r::Int)
    if !t.done[r] && !is_alternate(t) && has_text(t.screen[r])
        t.discarded += 1
    end
    return nothing
end

function remove_row!(t::Terminal, k::Int)
    discard_row!(t, k)
    deleteat!(t.screen, k)
    deleteat!(t.wrapped, k)
    deleteat!(t.done, k)
    return nothing
end

# ---- grid writes ------------------------------------------------------------

blank_cell(t::Terminal) = Cell(' ', Style(-1, t.style.bg, 0x00))

function blank_row(t::Terminal)
    return fill(blank_cell(t), t.cols)
end

function erase_cells!(t::Terminal, r::Int, c1::Int, c2::Int)
    row = t.screen[r]
    blank = blank_cell(t)
    changed = false
    for c in c1:c2
        if row[c] != blank
            row[c] = blank
            changed = true
        end
    end
    if changed && t.done[r]
        t.rewrites += 1
    end
    return nothing
end

function erase_line!(t::Terminal, mode::Int)
    t.pending_wrap = false
    if mode == 0
        erase_cells!(t, t.row, t.col, t.cols)
    elseif mode == 1
        erase_cells!(t, t.row, 1, t.col)
    elseif mode == 2
        erase_cells!(t, t.row, 1, t.cols)
    else
        ignore!(t, "EL $mode")
    end
    return nothing
end

# Clears the whole screen. The screen's lines are emitted first, so the text is kept in the log.
function clear_screen!(t::Terminal)
    emit_screen!(t)
    fill!(t.done, false)
    fill!(t.wrapped, false)
    for r in 1:t.rows
        erase_cells!(t, r, 1, t.cols)
    end
    return nothing
end

# Erasing from the cursor or up to it is how the child redraws its own text, so the erased text is
# not emitted and is not counted as discarded.
function erase_display!(t::Terminal, mode::Int)
    t.pending_wrap = false
    if mode == 0
        erase_cells!(t, t.row, t.col, t.cols)
        for r in (t.row + 1):t.rows
            erase_cells!(t, r, 1, t.cols)
        end
    elseif mode == 1
        for r in 1:(t.row - 1)
            erase_cells!(t, r, 1, t.cols)
        end
        erase_cells!(t, t.row, 1, t.col)
    elseif mode == 2
        clear_screen!(t)
    else
        # Erasing the scrollback has no effect here: the log is not the parser's scrollback.
        ignore!(t, "ED $mode")
    end
    return nothing
end

function insert_chars!(t::Terminal, n::Int)
    row = t.screen[t.row]
    before = copy(row)
    n = min(n, t.cols - t.col + 1)
    for c in t.cols:-1:(t.col + n)
        row[c] = row[c - n]
    end
    erase_cells!(t, t.row, t.col, t.col + n - 1)
    if t.done[t.row] && row != before
        t.rewrites += 1
    end
    return nothing
end

function delete_chars!(t::Terminal, n::Int)
    row = t.screen[t.row]
    before = copy(row)
    n = min(n, t.cols - t.col + 1)
    for c in t.col:(t.cols - n)
        row[c] = row[c + n]
    end
    erase_cells!(t, t.row, t.cols - n + 1, t.cols)
    if t.done[t.row] && row != before
        t.rewrites += 1
    end
    return nothing
end

function insert_lines!(t::Terminal, n::Int)
    (t.top <= t.row <= t.bottom) || return nothing
    t.row == t.top && emit_pending!(t)
    for _ in 1:min(n, t.bottom - t.row + 1)
        remove_row!(t, t.bottom)
        insert!(t.screen, t.row, blank_row(t))
        insert!(t.wrapped, t.row, false)
        insert!(t.done, t.row, false)
    end
    t.col = 1
    t.pending_wrap = false
    return nothing
end

function delete_lines!(t::Terminal, n::Int)
    (t.top <= t.row <= t.bottom) || return nothing
    t.row == t.top && emit_pending!(t)
    for _ in 1:min(n, t.bottom - t.row + 1)
        remove_row!(t, t.row)
        insert!(t.screen, t.bottom, blank_row(t))
        insert!(t.wrapped, t.bottom, false)
        insert!(t.done, t.bottom, false)
    end
    t.col = 1
    t.pending_wrap = false
    return nothing
end

function reverse_index!(t::Terminal)
    t.pending_wrap = false
    if t.row == t.top
        scroll_down!(t, 1)
    else
        t.row -= 1
    end
    return nothing
end

# Resets the terminal. The main screen's lines are emitted first, as for ED 2; the alternate screen
# is discarded, as the reset ends it.
function reset!(t::Terminal)
    t.main === nothing || leave_alternate!(t, false)
    t.style = DEFAULT_STYLE
    clear_screen!(t)
    t.top, t.bottom = 1, t.rows
    t.cursor_visible = true
    t.bracketed_paste = false
    t.application_cursor = false
    t.row, t.col, t.pending_wrap = 1, 1, false
    return nothing
end

function put_char!(t::Terminal, c::Char)
    if t.pending_wrap
        t.pending_wrap = false
        t.col = 1
        if t.row == t.bottom
            scroll_up!(t, 1)
        else
            t.row = min(t.row + 1, t.rows)
        end
        t.wrapped[t.row] = true
    end
    row = t.screen[t.row]
    new = Cell(c, t.style)
    if row[t.col] != new
        if t.done[t.row]
            t.rewrites += 1
        end
        row[t.col] = new
    end
    if t.col == t.cols
        t.pending_wrap = true
    else
        t.col += 1
    end
    return nothing
end

# Line feed: the cursor moves down, scrolling the region when it is on the bottom row.
function line_feed!(t::Terminal)
    t.pending_wrap = false
    if t.row == t.bottom
        scroll_up!(t, 1)
    else
        t.row = min(t.row + 1, t.rows)
    end
    return nothing
end

# Scrolls the scroll region up by `n` rows. A row leaving the top that has not been emitted is
# handed to `leave_top!`. A row leaving a full-screen region is also kept in the scrollback.
function scroll_up!(t::Terminal, n::Int)
    for _ in 1:n
        T = t.top
        if !is_alternate(t)
            if T == 1 && t.bottom == t.rows
                push!(t.scrollback, copy(t.screen[T]))
                length(t.scrollback) > SCROLLBACK_ROWS && popfirst!(t.scrollback)
            end
            if !t.done[T]
                leave_top!(t, T)
            end
        end
        deleteat!(t.screen, T)
        deleteat!(t.wrapped, T)
        deleteat!(t.done, T)
        insert!(t.screen, t.bottom, blank_row(t))
        insert!(t.wrapped, t.bottom, false)
        insert!(t.done, t.bottom, false)
    end
    return nothing
end

function scroll_down!(t::Terminal, n::Int)
    emit_pending!(t)
    for _ in 1:n
        remove_row!(t, t.bottom)
        insert!(t.screen, t.top, blank_row(t))
        insert!(t.wrapped, t.top, false)
        insert!(t.done, t.top, false)
    end
    return nothing
end

# ---- alternate screen -------------------------------------------------------

# Switches to a blank screen. The main screen is kept in `t.main`, and nothing is emitted until
# the alternate screen is left.
function enter_alternate!(t::Terminal, save_cursor::Bool)
    is_alternate(t) && return nothing
    save_cursor && save_cursor!(t)
    t.main = SavedScreen(t.screen, t.wrapped, t.done, t.row, t.col, t.pending_wrap, t.top, t.bottom, t.pending)
    t.screen = [fill(BLANK_CELL, t.cols) for _ in 1:t.rows]
    t.wrapped = fill(false, t.rows)
    t.done = fill(false, t.rows)
    t.pending = Vector{Cell}[]
    t.row, t.col, t.pending_wrap = 1, 1, false
    t.top, t.bottom = 1, t.rows
    return nothing
end

function leave_alternate!(t::Terminal, restore_cursor::Bool)
    m = t.main
    m === nothing && return nothing
    t.main = nothing
    t.screen, t.wrapped, t.done = m.screen, m.wrapped, m.done
    t.row, t.col, t.pending_wrap = m.row, m.col, m.pending_wrap
    t.top, t.bottom, t.pending = m.top, m.bottom, m.pending
    if restore_cursor
        t.style = t.saved_style
    end
    return nothing
end

# ---- resize -----------------------------------------------------------------

"""
    resize_screen!(t, rows, cols)

Change the screen size. Columns are truncated or padded with blanks. Rows are removed from the
bottom when they lie below the cursor, and otherwise from the top, where they are handled as rows
leaving the screen (appended to the log, unless the alternate screen is active). The scroll region
is reset to the whole screen. Lines already in the log are not reflowed. Text removed by truncation
or by removing a row from the bottom is counted as discarded when the row had not been emitted.
"""
function resize_screen!(t::Terminal, rows::Integer, cols::Integer)
    r, c = Int(rows), Int(cols)
    (r >= 1 && c >= 1) || throw(ArgumentError("terminal size must be at least 1 by 1, got $rows by $cols"))
    old_rows = t.rows
    old_top = t.top
    if old_top != 1
        emit_pending!(t)
    end
    t.top, t.bottom = 1, old_rows
    for k in eachindex(t.screen)
        row = t.screen[k]
        if c < length(row) && !t.done[k] && !is_alternate(t) && has_text(row[(c + 1):end])
            t.discarded += 1
        end
        n = length(row)
        if c < n
            resize!(row, c)
        else
            append!(row, fill(blank_cell(t), c - n))
        end
    end
    if r > old_rows
        for _ in 1:(r - old_rows)
            push!(t.screen, fill(blank_cell(t), c))
            push!(t.wrapped, false)
            push!(t.done, false)
        end
    elseif r < old_rows
        below = old_rows - t.row
        from_bottom = min(below, old_rows - r)
        for _ in 1:from_bottom
            remove_row!(t, length(t.screen))
        end
        from_top = old_rows - r - from_bottom
        for _ in 1:from_top
            t.done[1] || is_alternate(t) || leave_top!(t, 1)
            deleteat!(t.screen, 1)
            deleteat!(t.wrapped, 1)
            deleteat!(t.done, 1)
            t.row -= 1
        end
    end
    t.rows, t.cols = r, c
    t.top, t.bottom = 1, r
    t.row = clamp(t.row, 1, r)
    t.col = clamp(t.col, 1, c)
    t.pending_wrap = false
    t.saved_row = clamp(t.saved_row, 1, r)
    t.saved_col = clamp(t.saved_col, 1, c)
    if t.main !== nothing
        resize_saved!(t, t.main, r, c)
    end
    return t
end

# While the alternate screen is active, the main screen is resized in place and nothing is emitted.
# Its text that is cut off, or in rows removed, is counted as discarded when the row was not emitted.
function resize_saved!(t::Terminal, m::SavedScreen, r::Int, c::Int)
    for k in eachindex(m.screen)
        row = m.screen[k]
        if c < length(row) && !m.done[k] && has_text(row[(c + 1):end])
            t.discarded += 1
        end
        n = length(row)
        c < n ? resize!(row, c) : append!(row, fill(BLANK_CELL, c - n))
    end
    n = length(m.screen)
    if r < n
        for k in (r + 1):n
            if !m.done[k] && has_text(m.screen[k])
                t.discarded += 1
            end
        end
        resize!(m.screen, r)
        resize!(m.wrapped, r)
        resize!(m.done, r)
    else
        for _ in (n + 1):r
            push!(m.screen, fill(BLANK_CELL, c))
            push!(m.wrapped, false)
            push!(m.done, false)
        end
    end
    if any(has_text, m.pending)
        t.discarded += 1
    end
    empty!(m.pending)
    m.row = clamp(m.row, 1, r)
    m.col = clamp(m.col, 1, c)
    m.top, m.bottom = 1, r
    m.pending_wrap = false
    return m
end

# ---- SGR --------------------------------------------------------------------

function colour_code(v::Int)
    return 0 <= v <= 255 ? v : nothing
end

function rgb_code(r::Int, g::Int, b::Int)
    all(x -> 0 <= x <= 255, (r, g, b)) || return nothing
    return RGB_FLAG | (r << 16) | (g << 8) | b
end

first_or(v::Vector{Int}, default::Int) = isempty(v) ? default : v[1]

# Colour argument of SGR 38 or 48 whose group is group `i`. Returns the colour code (`nothing` if
# malformed) and the number of following groups it consumed.
function extended_colour(t::Terminal, i::Int)
    g = t.groups
    grp = g[i]
    if length(grp) >= 2
        # Colon form: 38:5:n, or 38:2:[colour space:]r:g:b.
        if grp[2] == 5 && length(grp) >= 3
            return colour_code(grp[3]), 0
        elseif grp[2] == 2 && length(grp) >= 5
            return rgb_code(grp[end - 2], grp[end - 1], grp[end]), 0
        end
        return nothing, 0
    end
    # Semicolon form: the arguments are the following groups.
    kind = i + 1 <= length(g) ? first_or(g[i + 1], -1) : -1
    if kind == 5 && i + 2 <= length(g)
        return colour_code(first_or(g[i + 2], -1)), 2
    elseif kind == 2 && i + 4 <= length(g)
        return rgb_code(first_or(g[i + 2], -1), first_or(g[i + 3], -1), first_or(g[i + 4], -1)), 4
    end
    return nothing, 0
end

function sgr!(t::Terminal)
    g = t.groups
    i = 1
    while i <= length(g)
        grp = g[i]
        p = (isempty(grp) || grp[1] < 0) ? 0 : grp[1]
        st = t.style
        fg, bg, at = Int(st.fg), Int(st.bg), st.attrs
        if p == 0
            fg, bg, at = -1, -1, 0x00
        elseif p == 1
            at |= ATTR_BOLD
        elseif p == 2
            at |= ATTR_DIM
        elseif p == 3
            at |= ATTR_ITALIC
        elseif p == 4
            at |= ATTR_UNDERLINE
        elseif p == 5
            at |= ATTR_BLINK
        elseif p == 7
            at |= ATTR_REVERSE
        elseif p == 9
            at |= ATTR_STRIKE
        elseif p == 22
            at &= ~(ATTR_BOLD | ATTR_DIM)
        elseif p == 23
            at &= ~ATTR_ITALIC
        elseif p == 24
            at &= ~ATTR_UNDERLINE
        elseif p == 25
            at &= ~ATTR_BLINK
        elseif p == 27
            at &= ~ATTR_REVERSE
        elseif p == 29
            at &= ~ATTR_STRIKE
        elseif 30 <= p <= 37
            fg = p - 30
        elseif 90 <= p <= 97
            fg = p - 82
        elseif p == 39
            fg = -1
        elseif 40 <= p <= 47
            bg = p - 40
        elseif 100 <= p <= 107
            bg = p - 92
        elseif p == 49
            bg = -1
        elseif p == 38 || p == 48
            code, used = extended_colour(t, i)
            if code === nothing
                ignore!(t, "SGR $p malformed")
            elseif p == 38
                fg = code
            else
                bg = code
            end
            i += used
        else
            ignore!(t, "SGR $p")
        end
        t.style = Style(Int32(fg), Int32(bg), at)
        i += 1
    end
    return nothing
end

# ---- public accessors -------------------------------------------------------

"""
    flush!(t, t_ns = t.now_ns)

Append the lines on the screen that have not been emitted, in order, and mark the screen as
emitted. Used when the process that wrote to the terminal has ended. If the alternate
screen is active, it is left first and only the main screen is emitted, since the process that
owned the alternate screen has gone.
"""
function flush!(t::Terminal, t_ns::UInt64 = t.now_ns)
    t.now_ns = t_ns
    is_alternate(t) && leave_alternate!(t, false)
    emit_screen!(t)
    return t
end

"""
    take_lines!(t) -> Vector{LogLine}

Return the lines appended since the last call, in order, and clear them from the terminal.
"""
function take_lines!(t::Terminal)
    lines = t.log
    t.log = LogLine[]
    return lines
end

"""
    live_line(t) -> Union{LogLine, Nothing}

The logical line containing the cursor row, if that line has not been emitted and holds text.
Returns `nothing` while the alternate screen is active.
"""
function live_line(t::Terminal)
    (is_alternate(t) || t.done[t.row]) && return nothing
    s = line_start(t, t.row)
    e = line_end(t, t.row)
    parts = line_parts(t, s, e)
    any(has_text, parts) || return nothing
    return build_line(parts, t.now_ns)
end

"""
    bracketed_paste(t) -> Bool

Whether the child has enabled bracketed paste (DEC private mode 2004).
"""
bracketed_paste(t::Terminal) = t.bracketed_paste

"""
    application_cursor(t) -> Bool

Whether the child has enabled application cursor keys (DEC private mode 1, DECCKM).
"""
application_cursor(t::Terminal) = t.application_cursor

"""
    counters(t) -> NamedTuple

`ignored` maps each ignored sequence to the number of times it occurred. `answered` maps each query
answered by the parser (see `answer_query!`) to the number of times it was answered. `rewrites` counts
writes that changed an emitted row. `discarded` counts text that was removed from the screen without being
emitted: text removed by insert or delete line, by scrolling down, by removing rows when the screen
shrinks, or by narrowing the screen. Erasing by the child (EL, ED 0, ED 1, ECH, DCH) is not counted,
since the child redraws such text.
"""
function counters(t::Terminal)
    return (ignored = copy(t.ignored), rewrites = t.rewrites, discarded = t.discarded,
        answered = copy(t.answered))
end

"""
    take_replies!(t) -> Vector{UInt8}

Return the replies to queries that have been parsed since the last call, in order, and clear them.
The caller writes them to the child. Replies are not counted as ignored or logged.

Answered queries, with their replies (`ESC` is written as `\\e`):
- `CSI 5 n`: `CSI 0 n` (device status report).
- `CSI 6 n`: `CSI row ; col R` (cursor position report).
- `CSI ? 6 n`: `CSI ? row ; col ; 1 R` (DEC cursor position report).
- `CSI c` and `CSI 0 c`: `CSI ? 1 ; 2 c` (primary device attributes, as a VT100 with advanced video).
- `CSI 18 t`: `CSI 8 ; rows ; cols t` (screen size in characters).

Positions are 1-based and relative to the screen; while the alternate screen is active they refer to
its cursor. The other queries are not answered and are counted in `ignored` under their names: `CSI > c`,
`CSI > q` (XTVERSION), `CSI ? Ps \$ p` (DECRQM), `CSI 14 t`, OSC colour queries, and `ENQ`.
"""
function take_replies!(t::Terminal)
    bytes = t.outbox
    t.outbox = UInt8[]
    return bytes
end

"""
    screen_lines(t) -> Vector{String}

Screen rows as strings, with trailing spaces removed.
"""
function screen_lines(t::Terminal)
    return [String(rstrip(String([c.char for c in t.screen[r]]))) for r in 1:t.rows]
end

"""
    row_finished(t, r) -> Bool

Whether screen row `r` has been emitted, so that its text is in the line log and it is not shown
from the screen.
"""
row_finished(t::Terminal, r::Integer) = t.done[Int(r)]

"""
    row_continues(t, r) -> Bool

Whether screen row `r` continues the logical line of the row above it, by automatic wrapping.
"""
row_continues(t::Terminal, r::Integer) = t.wrapped[Int(r)]

"""
    screen_row(t, r) -> Vector{Cell}

The cells of screen row `r`.
"""
screen_row(t::Terminal, r::Integer) = t.screen[Int(r)]

"""
    pending_rows(t) -> Vector{Vector{Cell}}

Rows that have left the top of the scroll region while their logical line continues on screen.
They are not on screen and not yet in the log; they precede screen row `top`.
"""
pending_rows(t::Terminal) = t.pending

screen_cell(t::Terminal, r::Int, c::Int) = t.screen[r][c]
cursor_pos(t::Terminal) = (t.row, t.col)

end # module
