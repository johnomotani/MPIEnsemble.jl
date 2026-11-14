const SB_PM = MPIEnsemble.PaneModel
const SB_LL = MPIEnsemble.LineLog
const SB_KM = MPIEnsemble.KeyMap

sb_bytes(s::AbstractString) = Vector{UInt8}(codeunits(s))

# A pane onto a log of `lines` numbered lines, showing `view` rows. `calls` counts notifications made
# after the setup. No window is opened.
function sb_pane(lines::Integer; rows = 5, view = 20)
    log = SB_LL.RankLog(0)
    term = SB_LL.begin_session!(log, 1, rows, 40)
    SB_LL.feed_output!(log, term, sb_bytes(join(("line $i" for i in 1:lines), "\r\n") * "\r\n"), 2)
    calls = Ref(0)
    pane = SB_PM.Pane(log, rows; notify = (p, kind, first, last) -> (calls[] += 1))
    SB_PM.attach!(pane, term)
    SB_PM.set_view_rows!(pane, view)
    calls[] = 0
    return (; log, term, pane, calls)
end

@testset "fraction to window top: the ends and ties" begin
    @test SB_PM.top_for_fraction(0, 1000, 20) == 1
    @test SB_PM.top_for_fraction(1, 1000, 20) == 981
    @test SB_PM.top_for_fraction(1 - 1e-12, 1000, 20) == 981
    @test SB_PM.top_for_fraction(1e-12, 1000, 20) == 1
    # Halves round up: 0.25 * 2 = 0.5 gives 1 + 1, and 0.75 * 2 = 1.5 gives 1 + 2.
    @test SB_PM.top_for_fraction(0.25, 12, 10) == 2
    @test SB_PM.top_for_fraction(0.75, 12, 10) == 3
    @test SB_PM.top_for_fraction(0.2499, 12, 10) == 1
    @test_throws ArgumentError SB_PM.top_for_fraction(-0.1, 1000, 20)
    @test_throws ArgumentError SB_PM.top_for_fraction(1.5, 1000, 20)
    @test_throws ArgumentError SB_PM.top_for_fraction(NaN, 1000, 20)
end

@testset "a sequence no longer than the view" begin
    @test SB_PM.top_for_fraction(0.7, 5, 10) == 1
    @test SB_PM.top_for_fraction(1, 10, 10) == 1
    @test SB_PM.thumb_position(1, 5, 10) == 0.0
    @test SB_PM.thumb_size(5, 10) == 1.0
    @test SB_PM.thumb_size(0, 10) == 1.0
    @test SB_PM.page_top(1, 1, 5, 10) == 1
end

@testset "thumb position and size" begin
    @test SB_PM.thumb_size(100, 10) ≈ 0.1
    @test SB_PM.thumb_position(1, 100, 10) == 0.0
    @test SB_PM.thumb_position(91, 100, 10) == 1.0
    @test SB_PM.thumb_position(46, 100, 10) ≈ 0.5
    # The top is limited to the sequence before mapping.
    @test SB_PM.thumb_position(500, 100, 10) == 1.0
    @test SB_PM.thumb_size(3_000_000, 40) ≈ 40 / 3_000_000
end

@testset "page steps: visible rows minus one, limited to the sequence" begin
    @test SB_PM.page_top(1, 1, 100, 10) == 10
    @test SB_PM.page_top(10, -1, 100, 10) == 1
    @test SB_PM.page_top(95, 1, 100, 10) == 91
    @test SB_PM.page_top(5, -1, 100, 10) == 1
    @test SB_PM.page_top(1, 1, 100, 1) == 2
    @test_throws ArgumentError SB_PM.page_top(1, 2, 100, 10)
end

@testset "round trips at lengths 100, 100000 and 3000000" begin
    for len in (100, 100_000, 3_000_000), visible in (20, 40)
        last = len - visible + 1
        tops = unique([1, 2, 3, 61, fld(last, 3), fld(last, 2), last - 1, last])
        for top in tops
            # Position to fraction to position: the same row.
            pos = SB_PM.thumb_position(top, len, visible)
            @test 0 <= pos <= 1
            @test SB_PM.top_for_fraction(pos, len, visible) == top
        end
        for f in (0.0, 0.1, 0.25, 1 / 3, 0.5, 0.75, 0.9, 0.999999, 1.0)
            # Fraction to position to fraction: within half a row of the sequence.
            top = SB_PM.top_for_fraction(f, len, visible)
            @test 1 <= top <= last
            @test abs(SB_PM.thumb_position(top, len, visible) - f) <= 0.5 / (len - visible)
        end
    end
end

@testset "jump operations on a pane" begin
    p = sb_pane(1000)
    pane = p.pane
    len = SB_PM.seq_length(pane)
    last = len - 20 + 1
    @test pane.follow
    @test pane.view_top == last
    @test SB_PM.scrollbar_state(pane) == (1.0, 20 / len)

    # Top: one refill, stops following, and the first row is at the top of the view.
    row = SB_PM.scroll_to_top!(pane)
    @test row == 1
    @test !pane.follow
    @test pane.view_top == 1
    @test p.calls[] == 1
    @test SB_PM.scrollbar_state(pane)[1] == 0.0

    # Middle: the view top is the fraction's row, and the rows shown are those of that position.
    p.calls[] = 0
    row = SB_PM.scroll_to_fraction!(pane, 0.5)
    @test p.calls[] == 1
    @test !pane.follow
    @test pane.view_top == SB_PM.top_for_fraction(0.5, len, 20)
    @test pane.top + row - 1 == pane.view_top
    @test SB_PM.scrollbar_state(pane)[1] ≈ (pane.view_top - 1) / (len - 20)
    # Log entry k is line k here, so the top of the view shows the line with the number of its position.
    @test SB_LL.window(p.log, pane.view_top:pane.view_top)[1].text == "line $(pane.view_top)"
    @test pane.rows[pane.view_top - pane.top + 1, 1] ==
        SB_PM.line_html("line $(pane.view_top)", SB_LL.window(p.log, pane.view_top:pane.view_top)[1].spans)

    # The same fraction again changes nothing and notifies nothing.
    p.calls[] = 0
    SB_PM.scroll_to_fraction!(pane, 0.5)
    @test p.calls[] == 0

    # Bottom: resumes following, notifies once, and returns 0 since the view follows the end.
    p.calls[] = 0
    @test SB_PM.scroll_to_bottom!(pane) == 0
    @test pane.follow
    @test p.calls[] == 1
    @test pane.view_top == last
    @test SB_PM.scrollbar_state(pane)[1] == 1.0

    # Dragging to fraction 1 is the bottom too.
    SB_PM.scroll_to_fraction!(pane, 0.2)
    @test !pane.follow
    @test SB_PM.scroll_to_fraction!(pane, 1.0) == 0
    @test pane.follow
    @test pane.view_top == last
end

@testset "fraction 0 and 1 on a pane" begin
    p = sb_pane(1000)
    pane = p.pane
    len = SB_PM.seq_length(pane)
    SB_PM.scroll_to_fraction!(pane, 0.0)
    @test pane.view_top == 1
    @test pane.top == 1
    @test !pane.follow
    @test SB_PM.scroll_to_fraction!(pane, 1.0) == 0
    @test pane.view_top == len - 19
    @test_throws ArgumentError SB_PM.scroll_to_fraction!(pane, 2)
end

@testset "page up and down stop and resume following" begin
    p = sb_pane(1000)
    pane = p.pane
    len = SB_PM.seq_length(pane)
    SB_PM.scroll_to_top!(pane)
    p.calls[] = 0
    # A page that stays within the matrix moves the view only, so there is no refill.
    @test SB_PM.page!(pane, 1) == 20 - pane.top + 1
    @test pane.view_top == 20
    @test !pane.follow
    @test p.calls[] == 0
    SB_PM.page!(pane, -1)
    @test pane.view_top == 1
    # Pages down from the middle: each page notifies at most once, and at least one refills the matrix.
    SB_PM.scroll_to_fraction!(pane, 0.5)
    start = pane.view_top
    refills = 0
    for k in 1:12
        before = p.calls[]
        SB_PM.page!(pane, 1)
        @test p.calls[] - before in (0, 1)
        refills += p.calls[] - before
    end
    @test refills >= 1
    @test pane.view_top == start + 12 * 19
    # Paging down from near the end reaches the end, which resumes following.
    SB_PM.scroll_to_fraction!(pane, 1.0)
    SB_PM.scroll_to_fraction!(pane, 0.99)
    @test !pane.follow
    @test SB_PM.page!(pane, 1) == 0
    @test pane.follow
    @test pane.view_top == len - 19
end

@testset "a view that is following keeps the end when the log grows" begin
    p = sb_pane(1000)
    pane = p.pane
    SB_LL.feed_output!(p.log, p.term, sb_bytes(join(("more $i" for i in 1:500), "\r\n") * "\r\n"), 3)
    SB_PM.refresh!(pane)
    @test pane.follow
    @test pane.view_top == SB_PM.seq_length(pane) - 19
    @test SB_PM.scrollbar_state(pane)[1] == 1.0
end

@testset "length growth between drags: the view stays, the thumb moves" begin
    p = sb_pane(1000)
    pane = p.pane
    SB_PM.scroll_to_fraction!(pane, 0.5)
    top = pane.view_top
    len0 = SB_PM.seq_length(pane)
    pos0, size0 = SB_PM.scrollbar_state(pane)
    SB_LL.feed_output!(p.log, p.term, sb_bytes(join(("more $i" for i in 1:1000), "\r\n") * "\r\n"), 3)
    SB_PM.refresh!(pane)
    @test !pane.follow
    @test pane.view_top == top
    len1 = SB_PM.seq_length(pane)
    @test len1 > len0
    pos1, size1 = SB_PM.scrollbar_state(pane)
    @test pos1 ≈ (top - 1) / (len1 - 20)
    @test pos1 < pos0
    @test size1 < size0
    # The next drag to the same fraction uses the new length.
    SB_PM.scroll_to_fraction!(pane, 0.5)
    @test pane.view_top == SB_PM.top_for_fraction(0.5, len1, 20)
end

@testset "a short sequence: the thumb fills the track and jumps do nothing" begin
    p = sb_pane(3)
    pane = p.pane
    @test SB_PM.scrollbar_state(pane) == (0.0, 1.0)
    SB_PM.scroll_to_fraction!(pane, 0.5)
    @test pane.view_top == 1
    @test SB_PM.scrollbar_state(pane) == (0.0, 1.0)
end

@testset "the view must show at least one row" begin
    p = sb_pane(10)
    @test_throws "the view must show at least 1 row, got 0" SB_PM.set_view_rows!(p.pane, 0)
    @test_throws "the view must show at least 1 row, got -3" SB_PM.set_view_rows!(p.pane, -3)
end

@testset "the view row count is clamped to MAX_VIEW_ROWS" begin
    # A view of MAX_VIEW_ROWS rows, centred in the matrix, leaves MARGIN_ROWS rows above and below.
    @test SB_PM.MAX_VIEW_ROWS == 140
    @test SB_PM.MAX_VIEW_ROWS == SB_PM.WINDOW_ROWS - 2 * SB_PM.MARGIN_ROWS
    for requested in (10, 100, 200, 260, 261, 500, 5000)
        shown = min(requested, SB_PM.MAX_VIEW_ROWS)
        p = sb_pane(1000; rows = 5, view = requested)
        pane = p.pane
        len = SB_PM.seq_length(pane)
        @test pane.view_rows == shown
        @test pane.follow
        @test pane.view_top == len - shown + 1
        @test SB_PM.scrollbar_state(pane) == (1.0, shown / len)

        SB_PM.scroll_to_top!(pane)
        @test pane.view_top == 1
        @test SB_PM.scrollbar_state(pane) == (0.0, shown / len)

        SB_PM.scroll_to_fraction!(pane, 0.5)
        @test pane.view_top == SB_PM.top_for_fraction(0.5, len, shown)
        @test SB_PM.scrollbar_state(pane)[1] ≈ (pane.view_top - 1) / (len - shown)

        # A page is shown - 1 rows, so from the top the view moves to row `shown`.
        SB_PM.scroll_to_top!(pane)
        SB_PM.page!(pane, 1)
        @test pane.view_top == shown
        @test !pane.follow

        @test SB_PM.scroll_action!(pane, :bottom) == 0
        @test pane.follow
        @test pane.view_top == len - shown + 1
    end
end

@testset "a pane taller than the matrix: construction and QML calls do not throw" begin
    log = SB_LL.RankLog(0)
    @test SB_PM.Pane(log, 400).view_rows == SB_PM.MAX_VIEW_ROWS
    @test SB_PM.Pane(log, 5).view_rows == 5

    # 300 screen rows, a pane taller than the 260-row matrix. The QML side passes the number of rows
    # in the view, which is then more than the matrix has.
    p = sb_pane(1000; rows = 300, view = 300)
    pane = p.pane
    @test size(pane.rows, 1) == SB_PM.WINDOW_ROWS
    @test pane.view_rows == SB_PM.MAX_VIEW_ROWS
    shift = SB_PM.user_scrolled!(pane, 1, 300, false)
    @test shift isa Int
    @test !pane.follow
    @test SB_PM.user_scrolled!(pane, 1, 300, true) isa Int
    @test_throws ArgumentError SB_PM.user_scrolled!(pane, 1, 0, false)
    @test_throws ArgumentError SB_PM.user_scrolled!(pane, 0, 10, false)
end

@testset "scroll chords: Shift+PageUp and Shift+PageDown; Ctrl+Home and Ctrl+End" begin
    shift, ctrl = SB_KM.MOD_SHIFT, SB_KM.MOD_CTRL
    @test SB_PM.scroll_action(SB_KM.KEY_PAGEUP, shift) === :page_up
    @test SB_PM.scroll_action(SB_KM.KEY_PAGEDOWN, shift) === :page_down
    @test SB_PM.scroll_action(SB_KM.KEY_HOME, ctrl) === :top
    @test SB_PM.scroll_action(SB_KM.KEY_END, ctrl) === :bottom
    # Keypad and group-switch bits do not change the action.
    @test SB_PM.scroll_action(SB_KM.KEY_PAGEUP, shift | 0x20000000) === :page_up
    # Any other modifier, or no modifier, is not a scroll chord.
    @test SB_PM.scroll_action(SB_KM.KEY_PAGEUP, 0) === nothing
    @test SB_PM.scroll_action(SB_KM.KEY_PAGEUP, ctrl) === nothing
    @test SB_PM.scroll_action(SB_KM.KEY_PAGEUP, shift | ctrl) === nothing
    @test SB_PM.scroll_action(SB_KM.KEY_HOME, 0) === nothing
    @test SB_PM.scroll_action(SB_KM.KEY_HOME, shift) === nothing
    @test SB_PM.scroll_action(SB_KM.KEY_END, ctrl | SB_KM.MOD_ALT) === nothing
    @test SB_PM.scroll_action(SB_KM.KEY_DOWN, ctrl) === nothing
    @test SB_PM.scroll_action(0x41, shift) === nothing
    # The keys still have their translations to the child for other modifiers.
    @test String(SB_KM.key_bytes(SB_KM.KEY_HOME, "", ctrl)) == "\e[1;5H"
end

@testset "scroll_action! carries out each action" begin
    p = sb_pane(1000)
    pane = p.pane
    SB_PM.scroll_action!(pane, :top)
    @test pane.view_top == 1
    SB_PM.scroll_action!(pane, :page_down)
    @test pane.view_top == 20
    SB_PM.scroll_action!(pane, :page_up)
    @test pane.view_top == 1
    @test SB_PM.scroll_action!(pane, :bottom) == 0
    @test pane.follow
    @test_throws ArgumentError SB_PM.scroll_action!(pane, :middle)
end
