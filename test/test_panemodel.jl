const PM = MPIEnsemble.PaneModel
const LL = MPIEnsemble.LineLog
const VTP = MPIEnsemble.VTParse

bytes_of(s::AbstractString) = Vector{UInt8}(codeunits(s))

# Text of rich text from `screen_html`/`line_html`, without markup.
plain(html::AbstractString) = rstrip(replace(replace(html, r"<[^>]*>" => ""), "&nbsp;" => " "))

# A log and terminal fed with `text`, and a pane showing the terminal. `calls` counts notifications.
function pane_with(text::AbstractString; rows = 5, cols = 40)
    log = LL.RankLog(0)
    term = LL.begin_session!(log, 1, rows, cols)
    LL.feed_output!(log, term, bytes_of(text), 2)
    calls = Ref(Tuple{Symbol, Int, Int}[])
    pane = PM.Pane(log, rows; notify = (p, kind, first, last) -> push!(calls[], (kind, first, last)))
    PM.attach!(pane, term)
    empty!(calls[])
    return (; log, term, pane, calls)
end

@testset "resume_following! returns the pane to the bottom" begin
    p = pane_with(join(("line $i" for i in 1:300), "\r\n"); rows = 5)
    @test p.pane.follow
    bottom = p.pane.top
    PM.user_scrolled!(p.pane, 1, 5, false)
    @test !p.pane.follow
    @test p.pane.top < bottom
    empty!(p.calls[])
    PM.resume_following!(p.pane)
    @test p.pane.follow
    @test p.pane.top == bottom
    @test p.calls[] == [(:change, 1, PM.WINDOW_ROWS)]
end

@testset "HTML escaping" begin
    @test PM.html_escape("a<b>&\"c\"") == "a&lt;b&gt;&amp;&quot;c&quot;"
    @test PM.html_escape("x  y") == "x&nbsp;&nbsp;y"
    @test PM.html_escape("tab\there") == "tab&nbsp;here"
    @test PM.html_escape("é└") == "é└"
end

@testset "palette and colour codes" begin
    @test PM.palette_hex(1) == "#cd0000"
    @test PM.palette_hex(16) == "#000000"
    @test PM.palette_hex(231) == "#ffffff"
    @test PM.palette_hex(232) == "#080808"
    @test_throws ArgumentError PM.palette_hex(256)
    @test PM.style_css(VTP.DEFAULT_STYLE) == ""
    @test PM.style_css(VTP.Style(Int32(1), Int32(-1), 0x00)) == "color:#cd0000"
    @test PM.style_css(VTP.Style(Int32(-1), Int32(-1), VTP.ATTR_REVERSE)) ==
        "color:#1a1b26;background-color:#c0caf5"
    truecolour = VTP.RGB_FLAG | 0x0080ff
    @test PM.style_css(VTP.Style(Int32(truecolour), Int32(-1), 0x00)) == "color:#0080ff"
end

@testset "line rows: spans on non-ASCII text and adjacent styles" begin
    # One row, so that the line leaves the screen with its line feed.
    p = pane_with("é\e[31mab└\e[32mcd\e[0m é\r\n"; rows = 1)
    entry = LL.window(p.log, 1:1)[1]
    @test entry.text == "éab└cd é"
    @test [entry.text[r] for (r, _) in entry.spans] == ["é", "ab└", "cd", " é"]
    html = PM.line_html(entry.text, entry.spans)
    @test html == "é<span style=\"color:#cd0000\">ab└</span><span style=\"color:#00cd00\">cd</span>&nbsp;é"
end

@testset "screen rows: colours, escaping and cursor cell" begin
    t = VTP.Terminal(2, 20)
    VTP.feed!(t, bytes_of("<\e[1mB\e[0m"))
    @test PM.screen_html(t, 1) == "&lt;<span style=\"color:#c0caf5;font-weight:bold\">B</span>"
    @test PM.screen_html(t, 1; cursor_col = 3) ==
        "&lt;<span style=\"color:#c0caf5;font-weight:bold\">B</span><span style=\"color:#1a1b26;background-color:#c0caf5\">&nbsp;</span>"
    @test PM.screen_html(t, 2) == ""
end

@testset "windowing follows the bottom and maps the cursor" begin
    text = join(("line $i\r\n" for i in 1:1000))
    # One row, so that every line is in the log and the cursor row is the only screen row.
    p = pane_with(text; rows = 1)
    n = length(p.log)
    N = size(p.pane.rows, 1)
    @test n == 1000
    @test size(p.pane.rows) == (PM.WINDOW_ROWS, 1)
    @test p.pane.follow
    # The last matrix row is the blank cursor row, which follows the last log entry.
    @test p.pane.rows[N, 1] == "<span style=\"color:#1a1b26;background-color:#c0caf5\">&nbsp;</span>"
    @test p.pane.rows[N - 1, 1] == PM.line_html(LL.window(p.log, n:n)[1].text, LL.window(p.log, n:n)[1].spans)
    @test p.pane.rows[N - 4, 1] == PM.line_html("line 997", LL.window(p.log, 997:997)[1].spans)
    @test PM.cursor_slot(p.pane) == (N, 1)
    # Text before the cursor on the cursor row moves the cursor column.
    LL.feed_output!(p.log, p.term, bytes_of("julia> 1+1"), 3)
    PM.refresh!(p.pane)
    @test PM.cursor_slot(p.pane) == (N, 11)
    @test occursin("background-color:#c0caf5", p.pane.rows[N, 1])
    @test occursin("julia&gt;", p.pane.rows[N, 1])
    empty!(p.calls[])
    PM.refresh!(p.pane)
    @test p.calls[] == [(:change, 1, N)]
end

@testset "one notification per refill" begin
    p = pane_with(join(("line $i\r\n" for i in 1:300)); rows = 4)
    N = size(p.pane.rows, 1)
    LL.feed_output!(p.log, p.term, bytes_of("more\r\n"), 4)
    empty!(p.calls[])
    PM.refresh!(p.pane)
    @test p.calls[] == [(:change, 1, N)]
    empty!(p.calls[])
    VTP.resize_screen!(p.term, 6, 40)
    PM.set_screen_rows!(p.pane, 6)
    @test p.calls[] == [(:change, 1, PM.WINDOW_ROWS)]
    @test size(p.pane.rows, 1) == PM.WINDOW_ROWS
end

@testset "scrolling up stops following; returning to the bottom resumes" begin
    p = pane_with(join(("line $i\r\n" for i in 1:1000)); rows = 4)
    pane = p.pane
    N = size(pane.rows, 1)
    count = 10
    # The view is at the bottom of the matrix and the user scrolls up a little.
    shift = PM.user_scrolled!(pane, N - count - 3, count, false)
    @test !pane.follow
    @test shift == 0
    # New output does not move a pane that is not following, and does not refill it.
    empty!(p.calls[])
    LL.feed_output!(p.log, p.term, bytes_of("late\r\n"), 5)
    PM.refresh!(pane)
    @test isempty(p.calls[])
    # Moving to the top of the matrix refills it, centred on the view, and reports the shift.
    top_before = pane.top
    empty!(p.calls[])
    shift = PM.user_scrolled!(pane, 1, count, false)
    @test shift < 0
    @test pane.top == top_before + shift
    @test p.calls[] == [(:change, 1, N)]
    # Scroll back to the bottom, one step at a time, until the matrix ends at the end of the log.
    steps = 0
    while !pane.follow && steps < 100
        PM.user_scrolled!(pane, N - count + 1, count, true)
        steps += 1
    end
    @test pane.follow
    @test PM.cursor_slot(pane) == (N, 1)
end

@testset "view positions are checked" begin
    p = pane_with("abc\r\n"; rows = 3)
    @test_throws ArgumentError PM.user_scrolled!(p.pane, 0, 3, true)
    @test_throws ArgumentError PM.user_scrolled!(p.pane, 1, 0, true)
    @test_throws ArgumentError PM.Pane(p.log, 0)
    @test_throws ErrorException PM.attach!(p.pane, VTP.Terminal(7, 40))
end

@testset "restart entries, then the screen rows that are not logged" begin
    log = LL.RankLog(0)
    term = LL.begin_session!(log, 1, 3, 20)
    LL.feed_output!(log, term, bytes_of("one\r\n"), 2)
    LL.end_session!(log, term, 3)
    term2 = LL.begin_session!(log, 4, 3, 20)
    pane = PM.Pane(log, 3)
    PM.attach!(pane, term2)
    LL.feed_output!(log, term2, bytes_of("two"), 5)
    PM.refresh!(pane)
    N = size(pane.rows, 1)
    @test startswith(pane.rows[N, 1], "two<span")
    @test pane.rows[N - 1, 1] == "<span style=\"color:#565f89\">---&nbsp;session&nbsp;2&nbsp;---</span>"
    @test pane.rows[N - 2, 1] == "one"
    @test pane.rows[N - 3, 1] == ""
end

@testset "pane shows the edited rows of a multi-line input" begin
    log = LL.RankLog(0)
    term = LL.begin_session!(log, 1, 6, 40)
    pane = PM.Pane(log, 6)
    PM.attach!(pane, term)
    LL.feed_output!(log, term, bytes_of("function f(x)\r\n  x+1\r\nend"), 2)
    LL.feed_output!(log, term, bytes_of("\e[2A\r\e[9C\e[Kg(y)"), 3)
    PM.refresh!(pane)
    N = size(pane.rows, 1)
    @test length(log) == 0
    @test [plain(pane.rows[N - 3 + k, 1]) for k in 1:3] == ["function g(y)", "  x+1", "end"]
    @test pane.rows[N + 1 - 4, 1] == ""
    @test PM.cursor_slot(pane) == (N - 2, 14)
end

@testset "blank rows below the last text are not shown, except the cursor row" begin
    p = pane_with("abc\r\n"; rows = 10)
    @test length(p.log) == 0
    N = size(p.pane.rows, 1)
    @test plain(p.pane.rows[N - 1, 1]) == "abc"
    @test p.pane.rows[N, 1] == "<span style=\"color:#1a1b26;background-color:#c0caf5\">&nbsp;</span>"
    @test p.pane.rows[N - 2, 1] == ""
    @test PM.cursor_slot(p.pane) == (N, 1)
end
