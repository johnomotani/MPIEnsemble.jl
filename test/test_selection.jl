const SEL_PM = MPIEnsemble.PaneModel
const SEL_LL = MPIEnsemble.LineLog
const SEL_VT = MPIEnsemble.VTParse

sel_bytes(s::AbstractString) = Vector{UInt8}(codeunits(s))

# A pane onto a log fed with `text`. `calls` counts notifications. The tests drive the pane only, so
# no window is opened.
function sel_pane(text::AbstractString; rows = 5, cols = 40)
    log = SEL_LL.RankLog(0)
    term = SEL_LL.begin_session!(log, 1, rows, cols)
    SEL_LL.feed_output!(log, term, sel_bytes(text), 2)
    calls = Ref(0)
    pane = SEL_PM.Pane(log, rows; notify = (p, kind, first, last) -> (calls[] += 1))
    SEL_PM.attach!(pane, term)
    calls[] = 0
    return (; log, term, pane, calls)
end

# Matrix row of sequence position `seq`.
sel_slot(pane, seq::Integer) = seq - pane.top + 1

# A selection whose anchor is sequence position `seq`, column `col`: a drag that moves one column on
# and ends there. A press and release without movement would clear it.
function sel_anchor!(pane, seq::Integer, col::Integer)
    SEL_PM.select_start!(pane, sel_slot(pane, seq), col)
    SEL_PM.select_extend!(pane, sel_slot(pane, seq), col + 1)
    SEL_PM.select_end!(pane)
    return nothing
end

@testset "word characters and word ranges" begin
    @test SEL_PM.is_word_char('a')
    @test SEL_PM.is_word_char('7')
    @test SEL_PM.is_word_char('_')
    @test SEL_PM.is_word_char('!')
    @test SEL_PM.is_word_char('?')
    @test SEL_PM.is_word_char('é')
    @test SEL_PM.is_word_char('日')
    @test !SEL_PM.is_word_char(' ')
    @test !SEL_PM.is_word_char('.')
    @test !SEL_PM.is_word_char('(')

    chars = collect("foo_bar! héllo")
    @test SEL_PM.word_range(chars, 2) == 1:8
    @test SEL_PM.word_range(chars, 8) == 1:8
    @test SEL_PM.word_range(chars, 11) == 10:14
    @test isempty(SEL_PM.word_range(chars, 9))
    @test isempty(SEL_PM.word_range(chars, 0))
    @test isempty(SEL_PM.word_range(chars, 15))
    @test isempty(SEL_PM.word_range(Char[], 1))
end

@testset "a backwards drag selects the same text as a forward drag" begin
    p = sel_pane("alpha\r\nbeta\r\ngamma\r\ndelta\r\n"; rows = 1)
    pane = p.pane
    @test length(p.log) == 4
    @test SEL_PM.selected_text(pane) === nothing
    SEL_PM.select_start!(pane, sel_slot(pane, 3), 2)
    SEL_PM.select_extend!(pane, sel_slot(pane, 1), 3)
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) == "pha\nbeta\nga"
    SEL_PM.clear_selection!(pane)
    SEL_PM.select_start!(pane, sel_slot(pane, 1), 3)
    SEL_PM.select_extend!(pane, sel_slot(pane, 3), 2)
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) == "pha\nbeta\nga"
end

@testset "extraction across log entries and screen rows, with trailing blanks removed" begin
    # Four rows: "ab", "cd" and "x  y" are on screen above the blank cursor row, so nothing is logged.
    p = sel_pane("ab   \r\ncd\r\nx  y\r\n"; rows = 4, cols = 10)
    pane = p.pane
    @test length(p.log) == 0
    @test SEL_PM.selected_text(pane) === nothing
    SEL_PM.select_start!(pane, sel_slot(pane, 1), 1)
    SEL_PM.select_extend!(pane, sel_slot(pane, 3), 10)
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) == "ab\ncd\nx  y"
    # A selection that ends in a blank row keeps the newline, without trailing blanks.
    SEL_PM.select_start!(pane, sel_slot(pane, 2), 2)
    SEL_PM.select_extend!(pane, sel_slot(pane, 4), 5)
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) == "d\nx  y\n"
end

@testset "a selection that crosses from the log into the screen" begin
    # Two lines leave the screen into the log; "three" and the cursor row remain on screen.
    p = sel_pane("one\r\ntwo\r\nthree\r\nfour\r\n"; rows = 3, cols = 20)
    pane = p.pane
    @test length(p.log) == 2
    @test SEL_PM.selected_text(pane) === nothing
    SEL_PM.select_start!(pane, sel_slot(pane, 2), 2)
    SEL_PM.select_extend!(pane, sel_slot(pane, 3), 5)
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) == "wo\nthree"
end

@testset "wrapped screen rows join without a newline" begin
    # "abcdefgh" wraps after five columns; "xy" is a new line.
    p = sel_pane("abcdefgh\r\nxy"; rows = 4, cols = 5)
    pane = p.pane
    @test length(p.log) == 0
    @test SEL_VT.row_continues(p.term, 2)
    SEL_PM.select_start!(pane, sel_slot(pane, 1), 1)
    SEL_PM.select_extend!(pane, sel_slot(pane, 2), 5)
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) == "abcdefgh"
    SEL_PM.select_start!(pane, sel_slot(pane, 1), 4)
    SEL_PM.select_extend!(pane, sel_slot(pane, 3), 1)
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) == "defgh\nx"
end

@testset "a selection wider than the matrix keeps its text as the matrix moves" begin
    text = join(("line $i\r\n" for i in 1:1000))
    p = sel_pane(text; rows = 1)
    pane = p.pane
    N = size(pane.rows, 1)
    count = 10
    @test length(p.log) == 1000
    steps = 0
    while pane.top > 1 && steps < 100
        SEL_PM.user_scrolled!(pane, 1, count, false)
        steps += 1
    end
    @test pane.top == 1
    SEL_PM.select_start!(pane, 1, 1)
    SEL_PM.select_extend!(pane, N, 8)
    SEL_PM.select_end!(pane)
    expected = join(("line $i" for i in 1:N), "\n")
    @test SEL_PM.selected_text(pane) == expected
    # Move the matrix to the end of the log, away from the start of the selection.
    steps = 0
    while !pane.follow && steps < 1000
        SEL_PM.user_scrolled!(pane, N - count + 1, count, true)
        steps += 1
    end
    @test pane.follow
    @test pane.top > N
    @test SEL_PM.selected_text(pane) == expected
end

@testset "word and line selection on ASCII and non-ASCII text" begin
    p = sel_pane("héllo wörld_1 foo!\r\nsecond line\r\n"; rows = 4, cols = 40)
    pane = p.pane
    # Double-click on the ö of "wörld_1".
    SEL_PM.select_word!(pane, sel_slot(pane, 1), 8)
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) == "wörld_1"
    # The ! is a word character.
    SEL_PM.select_word!(pane, sel_slot(pane, 1), 18)
    @test SEL_PM.selected_text(pane) == "foo!"
    # A double-click on a space selects nothing.
    SEL_PM.select_word!(pane, sel_slot(pane, 1), 14)
    @test SEL_PM.selected_text(pane) === nothing
    # Triple-click selects a line.
    SEL_PM.select_line!(pane, sel_slot(pane, 2))
    @test SEL_PM.selected_text(pane) == "second line"
end

@testset "triple-click on a wrapped row selects the logical line" begin
    p = sel_pane("abcdefgh\r\nxy"; rows = 4, cols = 5)
    pane = p.pane
    SEL_PM.select_line!(pane, sel_slot(pane, 2))
    @test SEL_PM.selected_text(pane) == "abcdefgh"
    SEL_PM.select_line!(pane, sel_slot(pane, 3))
    @test SEL_PM.selected_text(pane) == "xy"
end

@testset "a click clears the selection; empty selections are not text" begin
    p = sel_pane("abc\r\ndef\r\n"; rows = 4, cols = 10)
    pane = p.pane
    SEL_PM.select_start!(pane, sel_slot(pane, 1), 2)
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) === nothing
    # A word on the blank cursor row is not a word, and leaves no selection.
    SEL_PM.select_word!(pane, sel_slot(pane, 3), 1)
    @test SEL_PM.selected_text(pane) === nothing
    # Clearing with nothing selected does not refill.
    p.calls[] = 0
    SEL_PM.clear_selection!(pane)
    @test p.calls[] == 0
end

@testset "a drag is needed to extend, and each change refills once" begin
    p = sel_pane("abc\r\ndef\r\n"; rows = 4, cols = 10)
    pane = p.pane
    # A word selection is not a drag.
    SEL_PM.select_word!(pane, sel_slot(pane, 1), 1)
    @test_throws ErrorException SEL_PM.select_extend!(pane, 1, 1)
    p.calls[] = 0
    SEL_PM.clear_selection!(pane)
    p.calls[] = 0
    SEL_PM.select_start!(pane, sel_slot(pane, 1), 1)
    @test p.calls[] == 1
    SEL_PM.select_extend!(pane, sel_slot(pane, 2), 2)
    @test p.calls[] == 2
    SEL_PM.select_end!(pane)
    @test p.calls[] == 2
end

@testset "a key press during a drag clears the selection; the rest of the drag does nothing" begin
    p = sel_pane("abc\r\ndef\r\n"; rows = 4, cols = 10)
    pane = p.pane
    SEL_PM.select_start!(pane, sel_slot(pane, 1), 1)
    SEL_PM.clear_selection!(pane)
    SEL_PM.select_extend!(pane, sel_slot(pane, 2), 2)
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) === nothing
end

@testset "the highlight is drawn in the rows of the selection" begin
    p = sel_pane("abcd\r\nefgh\r\n"; rows = 4, cols = 10)
    pane = p.pane
    SEL_PM.select_start!(pane, sel_slot(pane, 1), 2)
    SEL_PM.select_extend!(pane, sel_slot(pane, 2), 3)
    SEL_PM.select_end!(pane)
    css = "background-color:#7aa2f7"
    @test occursin(css, pane.rows[sel_slot(pane, 1), 1])
    @test occursin(css, pane.rows[sel_slot(pane, 2), 1])
    @test !occursin(css, pane.rows[sel_slot(pane, 3), 1])
    @test SEL_PM.line_html("abcd", [(1:4, SEL_VT.DEFAULT_STYLE)]; selected = 2:3) ==
        "a<span style=\"color:#1a1b26;background-color:#7aa2f7\">bc</span>d"
    # Clearing the selection removes the highlight.
    SEL_PM.clear_selection!(pane)
    @test !occursin(css, pane.rows[sel_slot(pane, 1), 1])
end

@testset "log growth and lines scrolling off between selection and read" begin
    # Selection made on the screen, before "two" and "one" leave it.
    p = sel_pane("one\r\ntwo\r\nthree"; rows = 3, cols = 20)
    pane = p.pane
    SEL_PM.select_start!(pane, sel_slot(pane, 2), 1)
    SEL_PM.select_extend!(pane, sel_slot(pane, 3), 5)
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) == "two\nthree"
    SEL_LL.feed_output!(p.log, p.term, sel_bytes("\r\nfour\r\n"), 3)
    SEL_PM.refresh!(pane)
    @test length(p.log) == 2
    @test SEL_PM.selected_text(pane) == "two\nthree"
end

@testset "log growth in one batch, past a selected screen row" begin
    p = sel_pane("one\r\ntwo\r\nthree"; rows = 3, cols = 20)
    pane = p.pane
    SEL_PM.select_start!(pane, sel_slot(pane, 3), 1)
    SEL_PM.select_extend!(pane, sel_slot(pane, 3), 5)
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) == "three"
    SEL_LL.feed_output!(p.log, p.term, sel_bytes("\r\na\r\nb\r\nc\r\nd\r\n"), 3)
    SEL_PM.refresh!(pane)
    @test length(p.log) >= 4
    @test SEL_PM.selected_text(pane) == "three"
end

@testset "a selection is dropped when the screen changes kind or width" begin
    p = sel_pane("abc\r\ndef\r\n"; rows = 4, cols = 10)
    pane = p.pane
    SEL_PM.select_start!(pane, sel_slot(pane, 1), 1)
    SEL_PM.select_extend!(pane, sel_slot(pane, 2), 2)
    SEL_PM.select_end!(pane)
    SEL_VT.resize_screen!(p.term, 4, 12)
    SEL_PM.refresh!(pane)
    @test SEL_PM.selected_text(pane) === nothing

    SEL_PM.select_start!(pane, sel_slot(pane, 1), 1)
    SEL_PM.select_extend!(pane, sel_slot(pane, 2), 2)
    SEL_PM.select_end!(pane)
    SEL_LL.feed_output!(p.log, p.term, sel_bytes("\e[?1049h"), 4)
    SEL_PM.refresh!(pane)
    @test SEL_PM.selected_text(pane) === nothing
end

@testset "shift-extension moves the active end and keeps the anchor, flipping past it" begin
    p = sel_pane("alpha\r\nbeta\r\ngamma\r\ndelta\r\n"; rows = 1)
    pane = p.pane
    sel_anchor!(pane, 2, 2)
    SEL_PM.select_extend_start!(pane, sel_slot(pane, 3), 3)
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) == "eta\ngam"
    # Extending above the anchor flips the selection around it.
    SEL_PM.select_extend_start!(pane, sel_slot(pane, 1), 2)
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) == "lpha\nbe"
    # Back below the anchor, on the anchor's own row.
    SEL_PM.select_extend_start!(pane, sel_slot(pane, 2), 4)
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) == "eta"
    # A drag after a shift-press moves the same end.
    SEL_PM.select_extend_start!(pane, sel_slot(pane, 4), 1)
    SEL_PM.select_extend!(pane, sel_slot(pane, 3), 2)
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) == "eta\nga"
end

@testset "shift-extension across screen rows and wrapped rows" begin
    p = sel_pane("abc\r\ndef\r\nghi\r\n"; rows = 4, cols = 10)
    pane = p.pane
    @test length(p.log) == 0
    sel_anchor!(pane, 1, 2)
    SEL_PM.select_extend_start!(pane, sel_slot(pane, 3), 2)
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) == "bc\ndef\ngh"
    # Wrapped screen rows join without a newline, as for a plain drag.
    q = sel_pane("abcdefgh\r\nxy"; rows = 4, cols = 5)
    sel_anchor!(q.pane, 1, 4)
    SEL_PM.select_extend_start!(q.pane, sel_slot(q.pane, 3), 1)
    SEL_PM.select_end!(q.pane)
    @test SEL_PM.selected_text(q.pane) == "defgh\nx"
end

@testset "shift-extension beyond the matrix window" begin
    text = join(("line $i\r\n" for i in 1:1000))
    p = sel_pane(text; rows = 1)
    pane = p.pane
    N = size(pane.rows, 1)
    steps = 0
    while pane.top > 1 && steps < 100
        SEL_PM.user_scrolled!(pane, 1, 10, false)
        steps += 1
    end
    @test pane.top == 1
    sel_anchor!(pane, 5, 1)
    # Scroll to the end of the log. The anchor, line 5, is now above the matrix.
    steps = 0
    while !pane.follow && steps < 1000
        SEL_PM.user_scrolled!(pane, N - 9, 10, true)
        steps += 1
    end
    @test pane.follow
    t = pane.top
    @test t > 5 + N
    # A slot in the first row of the matrix is the first row shown, line t.
    SEL_PM.select_extend_start!(pane, 1, 3)
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) == join(("line $i" for i in 5:t-1), "\n") * "\nlin"
    # A slot below the matrix is clamped to its last row, the cursor row after line 1000.
    SEL_PM.select_extend_start!(pane, N + 50, 2)
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) == join(("line $i" for i in 5:1000), "\n") * "\n"
end

@testset "shift-extension after a double-click keeps the far edge of the word fixed" begin
    # "wörld_1" is columns 7:13 of the first row.
    p = sel_pane("héllo wörld_1 foo!\r\nsecond line\r\n"; rows = 4, cols = 40)
    pane = p.pane
    SEL_PM.select_word!(pane, sel_slot(pane, 1), 8)
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) == "wörld_1"
    # A click after the word keeps its start as the anchor.
    SEL_PM.select_extend_start!(pane, sel_slot(pane, 1), 17)
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) == "wörld_1 foo"
    # A click before the word keeps its end as the anchor, so the selection runs from the click to 13.
    SEL_PM.select_word!(pane, sel_slot(pane, 1), 8)
    SEL_PM.select_end!(pane)
    SEL_PM.select_extend_start!(pane, sel_slot(pane, 1), 3)
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) == "llo wörld_1"
    # A click inside the word keeps its start as the anchor.
    SEL_PM.select_word!(pane, sel_slot(pane, 1), 8)
    SEL_PM.select_end!(pane)
    SEL_PM.select_extend_start!(pane, sel_slot(pane, 1), 10)
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) == "wörl"
    # Once extended, the anchor is kept: the selection runs from the word start (column 7) to column 3.
    SEL_PM.select_extend_start!(pane, sel_slot(pane, 1), 3)
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) == "llo w"
end

@testset "shift-extension after a triple-click keeps the far edge of the line fixed" begin
    p = sel_pane("abc\r\ndef\r\nghi\r\n"; rows = 4, cols = 10)
    pane = p.pane
    SEL_PM.select_line!(pane, sel_slot(pane, 2))
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) == "def"
    SEL_PM.select_extend_start!(pane, sel_slot(pane, 3), 2)
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) == "def\ngh"
    SEL_PM.select_line!(pane, sel_slot(pane, 3))
    SEL_PM.select_end!(pane)
    SEL_PM.select_extend_start!(pane, sel_slot(pane, 1), 2)
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) == "bc\ndef\nghi"
end

@testset "shift-press with no selection is a plain press" begin
    p = sel_pane("abc\r\ndef\r\n"; rows = 4, cols = 10)
    pane = p.pane
    p.calls[] = 0
    SEL_PM.select_extend_start!(pane, sel_slot(pane, 1), 2)
    @test p.calls[] == 1
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) === nothing
    # With a drag, the press and drag select as a plain drag does.
    SEL_PM.select_extend_start!(pane, sel_slot(pane, 1), 2)
    SEL_PM.select_extend!(pane, sel_slot(pane, 2), 2)
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) == "bc\nde"
end

@testset "shift-press after the selection was cleared is a plain press" begin
    p = sel_pane("abc\r\ndef\r\n"; rows = 4, cols = 10)
    pane = p.pane
    SEL_PM.select_start!(pane, sel_slot(pane, 1), 1)
    SEL_PM.select_extend!(pane, sel_slot(pane, 2), 2)
    SEL_PM.select_end!(pane)
    SEL_PM.clear_selection!(pane)
    SEL_PM.select_extend_start!(pane, sel_slot(pane, 2), 3)
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) === nothing
    # A plain click that cleared the selection also leaves nothing to extend.
    SEL_PM.select_start!(pane, sel_slot(pane, 1), 1)
    SEL_PM.select_extend!(pane, sel_slot(pane, 2), 2)
    SEL_PM.select_end!(pane)
    SEL_PM.select_start!(pane, sel_slot(pane, 1), 1)
    SEL_PM.select_end!(pane)
    SEL_PM.select_extend_start!(pane, sel_slot(pane, 2), 3)
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) === nothing
end

@testset "shift-click on the anchor keeps a one-cell selection" begin
    p = sel_pane("abc\r\ndef\r\n"; rows = 4, cols = 10)
    pane = p.pane
    SEL_PM.select_start!(pane, sel_slot(pane, 1), 2)
    SEL_PM.select_extend!(pane, sel_slot(pane, 2), 2)
    SEL_PM.select_end!(pane)
    SEL_PM.select_extend_start!(pane, sel_slot(pane, 1), 2)
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) == "b"
end

@testset "shift-extension follows lines scrolling off the screen" begin
    p = sel_pane("one\r\ntwo\r\nthree"; rows = 3, cols = 20)
    pane = p.pane
    sel_anchor!(pane, 2, 1)
    SEL_LL.feed_output!(p.log, p.term, sel_bytes("\r\nfour\r\n"), 3)
    SEL_PM.refresh!(pane)
    @test length(p.log) == 2
    SEL_PM.select_extend_start!(pane, sel_slot(pane, 4), 2)
    SEL_PM.select_end!(pane)
    @test SEL_PM.selected_text(pane) == "two\nthree\nfo"
    # Lines leaving the screen while a selection is held keep its text, as for a drag.
    SEL_LL.feed_output!(p.log, p.term, sel_bytes("\r\nfive\r\n"), 3)
    SEL_PM.refresh!(pane)
    @test SEL_PM.selected_text(pane) == "two\nthree\nfo"
end

@testset "each shift-extension refills once and the selection text follows" begin
    p = sel_pane("abc\r\ndef\r\nghi\r\n"; rows = 4, cols = 10)
    pane = p.pane
    sel_anchor!(pane, 1, 1)
    p.calls[] = 0
    SEL_PM.select_extend_start!(pane, sel_slot(pane, 2), 2)
    @test p.calls[] == 1
    SEL_PM.select_extend!(pane, sel_slot(pane, 3), 1)
    @test p.calls[] == 2
    SEL_PM.select_end!(pane)
    @test p.calls[] == 2
    @test SEL_PM.selected_text(pane) == "abc\ndef\ng"
end
