const VT = MPIEnsemble.VTParse

const FIXTURE_DIR = joinpath(@__DIR__, "fixtures")
const FIXTURE_NAMES = ["a_startup", "b_eval_error", "c_colour", "d_editing", "e_paste",
    "f_long_output", "g_long_line", "h_modes", "i_resize"]

# Rows and columns used when each fixture was captured. i_resize was captured after a resize to
# 40x100; the byte stream does not record the resize, so it is replayed at its final size.
fixture_size(name::AbstractString) = name == "i_resize" ? (40, 100) : (24, 80)

# Chunks of a fixture as (arrival time, bytes), as recorded by the capture.
function load_chunks(name::AbstractString)
    bytes = read(joinpath(FIXTURE_DIR, name * ".bin"))
    rows = readlines(joinpath(FIXTURE_DIR, name * ".chunks.tsv"))[2:end]
    chunks = Tuple{UInt64, Vector{UInt8}}[]
    start = 1
    for row in rows
        t_str, end_str = split(row, '\t')
        stop = parse(Int, end_str)
        push!(chunks, (parse(UInt64, t_str), bytes[start:stop]))
        start = stop + 1
    end
    start - 1 == length(bytes) || error("$name: chunk table does not cover the byte file")
    return chunks
end

# Feeds a fixture chunk by chunk, or byte by byte within each chunk, then flushes the terminal as
# the child's exit does. `lines` is the whole log.
function replay_fixture(name::AbstractString; bytewise::Bool = false)
    rows, cols = fixture_size(name)
    t = VT.Terminal(rows, cols)
    lines = VT.LogLine[]
    for (t_ns, bytes) in load_chunks(name)
        if bytewise
            for i in eachindex(bytes)
                VT.feed!(t, bytes[i:i], t_ns)
            end
        else
            VT.feed!(t, bytes, t_ns)
        end
        append!(lines, VT.take_lines!(t))
    end
    VT.flush!(t)
    append!(lines, VT.take_lines!(t))
    return (; t, lines)
end

const PROMPT_LINE = r"^(julia|help\?|shell)>$"

# Texts of the log after the session ends. The final bare prompt is dropped, as tmux_expected drops
# it from the history: it is the live prompt, not output.
function logged_texts(name::AbstractString)
    texts = [rstrip(L.text) for L in replay_fixture(name).lines]
    if !isempty(texts) && occursin(PROMPT_LINE, texts[end])
        pop!(texts)
    end
    return texts
end

# Lines of the tmux history: rows that fill the width are joined to the row below, trailing blank
# rows and the final bare prompt (the live row) are removed.
function tmux_expected(name::AbstractString)
    _, cols = fixture_size(name)
    raw = [String(rstrip(l)) for l in readlines(joinpath(FIXTURE_DIR, "tmux", name * ".history.txt"))]
    out = String[]
    i = 1
    while i <= length(raw)
        line = raw[i]
        while length(raw[i]) == cols && i < length(raw)
            i += 1
            line *= raw[i]
        end
        push!(out, line)
        i += 1
    end
    while !isempty(out) && isempty(out[end])
        pop!(out)
    end
    if !isempty(out) && occursin(PROMPT_LINE, out[end])
        pop!(out)
    end
    return out
end

function feed_string(t::VT.Terminal, s::AbstractString)
    VT.feed!(t, Vector{UInt8}(codeunits(s)), UInt64(1))
    return t
end

@testset "fixtures against tmux history" begin
    for name in FIXTURE_NAMES
        name == "b_eval_error" && continue
        @testset "$name" begin
            @test logged_texts(name) == tmux_expected(name)
        end
    end

    @testset "b_eval_error: REPL numbering differs from tmux" begin
        texts = logged_texts("b_eval_error")
        expected = tmux_expected("b_eval_error")
        @test length(texts) == length(expected)
        @test findall(texts .!= expected) == [13, 15]
        @test texts[13] == replace(expected[13], "REPL[1]" => "REPL[2]")
        @test texts[15] == replace(expected[15], "REPL[2]" => "REPL[3]")
    end
end

@testset "fixtures leave no rewrites, discards or ignored sequences" begin
    for name in FIXTURE_NAMES
        c = VT.counters(replay_fixture(name).t)
        @test c.rewrites == 0
        @test c.discarded == 0
        @test isempty(c.ignored)
    end
end

@testset "byte-at-a-time feeding matches chunk feeding" begin
    for name in FIXTURE_NAMES
        whole = replay_fixture(name)
        bytewise = replay_fixture(name; bytewise = true)
        @test bytewise.lines == whole.lines
        @test VT.screen_lines(bytewise.t) == VT.screen_lines(whole.t)
        @test VT.counters(bytewise.t) == VT.counters(whole.t)
        @test VT.cursor_pos(bytewise.t) == VT.cursor_pos(whole.t)
    end
end

@testset "split at every byte, including inside UTF-8 and escape sequences" begin
    stream = Vector{UInt8}(codeunits("é\e[31mred\e[0m\r\n日本\e]0;title\a\e[2;3Hx\e[38;5;1mé\r\n\e[?1049halt\r\n\e[?1049lend\r\n"))
    whole = VT.Terminal(4, 20)
    VT.feed!(whole, stream, UInt64(7))
    expected_lines = VT.take_lines!(whole)
    expected_screen = VT.screen_lines(whole)
    for k in 1:(length(stream) - 1)
        t = VT.Terminal(4, 20)
        VT.feed!(t, stream[1:k], UInt64(7))
        VT.feed!(t, stream[(k + 1):end], UInt64(7))
        @test VT.take_lines!(t) == expected_lines
        @test VT.screen_lines(t) == expected_screen
    end
end

@testset "spans are byte ranges that slice non-ASCII text" begin
    for name in FIXTURE_NAMES
        for L in replay_fixture(name).lines
            pieces = [L.text[r] for (r, _) in L.spans]
            @test join(pieces) == L.text
            @test all(r -> first(r) >= 1 && last(r) <= ncodeunits(L.text), (r for (r, _) in L.spans))
        end
    end

    lines = replay_fixture("c_colour").lines
    warning = [(L.text[r], st) for L in lines for (r, st) in L.spans if startswith(L.text[r], "┌")]
    @test length(warning) == 1
    @test warning[1][1] == "┌ Warning: "
    @test warning[1][2].fg == 3
    @test (warning[1][2].attrs & VT.ATTR_BOLD) != 0

    t = VT.Terminal(2, 20)
    feed_string(t, "\e[31mé└\e[0m x\r\n")
    VT.flush!(t)
    L = VT.take_lines!(t)[1]
    @test L.text == "é└ x"
    @test [L.text[r] for (r, _) in L.spans] == ["é└", " x"]
end

@testset "emission rule" begin
    @testset "line feed on the last row does not emit; the line stays on screen" begin
        t = feed_string(VT.Terminal(3, 10), "ab\r\n")
        @test isempty(VT.take_lines!(t))
        @test VT.screen_lines(t) == ["ab", "", ""]
    end

    @testset "carriage return, cursor forward, erase and insert do not emit" begin
        t = feed_string(VT.Terminal(3, 10), "abc\r\e[2Cdef\e[1G\e[K\e[2X\e[@")
        @test isempty(VT.take_lines!(t))
        @test VT.live_line(t) === nothing
    end

    @testset "automatic wrap does not emit; the row joins the line" begin
        t = feed_string(VT.Terminal(3, 5), "abcdefgh")
        @test isempty(VT.take_lines!(t))
        live = VT.live_line(t)
        @test live.text == "abcdefgh"
        @test live.nrows == 2
    end

    @testset "a wrapped line that scrolls off is emitted once with its full text" begin
        # The first row leaves while its line continues, so it is held; the line is emitted when its
        # last row leaves.
        t = feed_string(VT.Terminal(2, 5), "abcdefgh\r\n")
        @test isempty(VT.take_lines!(t))
        t = feed_string(t, "\r\n")
        lines = VT.take_lines!(t)
        @test [L.text for L in lines] == ["abcdefgh"]
        @test lines[1].nrows == 2
    end

    @testset "explicit cursor motion off a row does not emit it" begin
        t = feed_string(VT.Terminal(4, 40), "abc\e[1Bx")
        @test isempty(VT.take_lines!(t))
        @test VT.screen_lines(t)[1:2] == ["abc", "   x"]
    end

    @testset "cursor motion off a blank row does not emit it" begin
        t = feed_string(VT.Terminal(4, 40), "\e[1B\e[1Ax\r\n")
        @test isempty(VT.take_lines!(t))
        VT.flush!(t)
        @test [L.text for L in VT.take_lines!(t)] == ["x"]
    end

    @testset "scroll-off of a top row with text emits it" begin
        t = feed_string(VT.Terminal(3, 5), "abc\e[S")
        @test [L.text for L in VT.take_lines!(t)] == ["abc"]
    end

    @testset "row leaving the top of a scroll region emits it" begin
        t = feed_string(VT.Terminal(4, 10), "\e[2;4r\e[2;1Hu\e[S")
        @test [L.text for L in VT.take_lines!(t)] == ["u"]
    end

    @testset "flush emits every unemitted line with text, once, in order" begin
        t = feed_string(VT.Terminal(3, 10), "julia> ")
        VT.flush!(t, UInt64(9))
        lines = VT.take_lines!(t)
        @test [L.text for L in lines] == ["julia>"]
        @test lines[1].t_ns == 9
        VT.flush!(t)
        @test isempty(VT.take_lines!(t))

        # A blank row between two lines of text is a line of the output.
        t = feed_string(VT.Terminal(4, 10), "a\r\nb\r\n\r\nc")
        VT.flush!(t)
        @test [L.text for L in VT.take_lines!(t)] == ["a", "b", "", "c"]
    end

    @testset "the lines on screen are emitted after the lines that scrolled off" begin
        t = feed_string(VT.Terminal(2, 10), "one\r\ntwo\r\nthr")
        @test [L.text for L in VT.take_lines!(t)] == ["one"]
        VT.flush!(t)
        @test [L.text for L in VT.take_lines!(t)] == ["two", "thr"]
    end
end

@testset "multi-line input edited on screen (cursor up, carriage return, erase, rewrite)" begin
    # The REPL redraws an earlier line of a block: up two rows, carriage return, move right, erase
    # to the end of the line, and write the new text.
    t = feed_string(VT.Terminal(6, 40), "function f(x)\r\n  x+1\r\nend")
    feed_string(t, "\e[2A\r\e[9C\e[Kg(y)")
    @test VT.screen_lines(t)[1:3] == ["function g(y)", "  x+1", "end"]
    @test isempty(VT.take_lines!(t))
    @test VT.counters(t).rewrites == 0
    @test VT.counters(t).discarded == 0
    VT.flush!(t)
    @test [L.text for L in VT.take_lines!(t)] == ["function g(y)", "  x+1", "end"]
end

@testset "scrolled-off lines carry their final text, in order, once each" begin
    t = feed_string(VT.Terminal(3, 10), "A\r\nB\r\nC\e[2A\rX\e[2B\r\nD\r\nE\r\nF")
    @test [L.text for L in VT.take_lines!(t)] == ["X", "B", "C"]
    @test VT.screen_lines(t) == ["D", "E", "F"]
    VT.flush!(t)
    @test [L.text for L in VT.take_lines!(t)] == ["D", "E", "F"]
end

@testset "clearing the screen emits its lines first" begin
    @testset "ED 2" begin
        t = feed_string(VT.Terminal(4, 20), "one\r\ntwo\r\nthr\e[2J")
        @test [L.text for L in VT.take_lines!(t)] == ["one", "two", "thr"]
        @test VT.screen_lines(t) == ["", "", "", ""]
        @test VT.counters(t).discarded == 0
        @test VT.counters(t).rewrites == 0
        feed_string(t, "\e[Hafter")
        VT.flush!(t)
        @test [L.text for L in VT.take_lines!(t)] == ["after"]
    end

    @testset "RIS" begin
        t = feed_string(VT.Terminal(4, 20), "x\r\ny\ec")
        @test [L.text for L in VT.take_lines!(t)] == ["x", "y"]
        @test VT.screen_lines(t) == ["", "", "", ""]
    end

    @testset "ED 3 is ignored and does not clear the screen" begin
        t = feed_string(VT.Terminal(4, 20), "kept\e[3J")
        @test isempty(VT.take_lines!(t))
        @test VT.screen_lines(t)[1] == "kept"
        @test VT.counters(t).ignored == Dict("ED 3" => 1)
    end
end

@testset "wrapped line that scrolls off with a line below it" begin
    t = feed_string(VT.Terminal(2, 5), "abcdefgh\r\nxy\r\n")
    @test [L.text for L in VT.take_lines!(t)] == ["abcdefgh"]
    VT.flush!(t)
    @test [L.text for L in VT.take_lines!(t)] == ["xy"]
end

@testset "alternate screen is suppressed and restored" begin
    t = feed_string(VT.Terminal(5, 20), "before\r\n\e[?1049halt1\r\nalt2\r\n\e[?1049lafter\r\n")
    @test isempty(VT.take_lines!(t))
    @test !VT.is_alternate(t)
    @test VT.screen_lines(t)[1:2] == ["before", "after"]
    VT.flush!(t)
    @test [L.text for L in VT.take_lines!(t)] == ["before", "after"]
end

@testset "flush while the alternate screen is active emits the main screen only" begin
    t = feed_string(VT.Terminal(4, 20), "main\r\n\e[?1049halt")
    VT.flush!(t)
    @test !VT.is_alternate(t)
    @test [L.text for L in VT.take_lines!(t)] == ["main"]
end

@testset "alternate screen shows no live row" begin
    t = feed_string(VT.Terminal(3, 20), "\e[?1049hshown")
    @test VT.is_alternate(t)
    @test VT.live_line(t) === nothing
end

@testset "edits to screen rows are not rewrites" begin
    t = feed_string(VT.Terminal(3, 20), "line1\r\n\e[1A\rEDIT")
    @test VT.screen_lines(t)[1:2] == ["EDIT1", ""]
    @test isempty(VT.take_lines!(t))
    @test VT.counters(t).rewrites == 0
end

@testset "writes into an emitted row are counted as rewrites" begin
    t = feed_string(VT.Terminal(3, 20), "line1\r\n")
    VT.flush!(t)
    @test [L.text for L in VT.take_lines!(t)] == ["line1"]
    feed_string(t, "\e[1A\rX")
    @test VT.counters(t).rewrites == 1
    @test VT.row_finished(t, 1)
end

@testset "discarded text is counted" begin
    t = feed_string(VT.Terminal(3, 10), "abc\r\ndef\e[1;1H\e[M")
    @test VT.counters(t).discarded == 1
    @test isempty(VT.take_lines!(t))
    t = feed_string(VT.Terminal(3, 10), "abc\e[K\e[2J")
    @test VT.counters(t).discarded == 0
end

@testset "ignored sequences are counted by name" begin
    t = feed_string(VT.Terminal(3, 10), "\e[2 q\e[5 q\e[7n\e[>4;1m")
    @test VT.counters(t).ignored == Dict("CSI intermediate q" => 2, "CSI n" => 1, "CSI > ... m" => 1)
    t = feed_string(VT.Terminal(3, 10), "\e[?7h")
    @test VT.counters(t).ignored == Dict("CSI ? 7 h" => 1)
end

@testset "scroll-back is capped" begin
    t = VT.Terminal(3, 5)
    feed_string(t, repeat("x\r\n", 300))
    @test length(t.scrollback) == VT.SCROLLBACK_ROWS
end

@testset "parameters saturate instead of overflowing" begin
    t = feed_string(VT.Terminal(5, 10), "\e[99999999999999999999999;99999999999999999999999Hx")
    @test VT.cursor_pos(t) == (5, 10)
end

@testset "probes: single sequences" begin
    @testset "OSC terminated by BEL" begin
        t = feed_string(VT.Terminal(4, 40), "\e]0;title\aok")
        @test VT.screen_lines(t)[1] == "ok"
        @test VT.counters(t).ignored["OSC"] == 1
    end
    @testset "OSC terminated by ST" begin
        t = feed_string(VT.Terminal(4, 40), "\e]0;title\e\\ok")
        @test VT.screen_lines(t)[1] == "ok"
    end
    @testset "backspace then overwrite" begin
        @test VT.screen_lines(feed_string(VT.Terminal(4, 40), "ab\b\bX"))[1] == "Xb"
    end
    @testset "horizontal tab" begin
        @test VT.screen_lines(feed_string(VT.Terminal(4, 40), "a\tb"))[1] == "a       b"
    end
    @testset "erase to end of display" begin
        @test VT.screen_lines(feed_string(VT.Terminal(4, 40), "abc\e[Jok"))[1] == "abcok"
    end
    @testset "alternate screen enter" begin
        t = feed_string(VT.Terminal(4, 40), "\e[?1049hok")
        @test VT.is_alternate(t)
        @test VT.screen_lines(t)[1] == "ok"
    end
    @testset "save and restore cursor (CSI s, CSI u)" begin
        @test VT.screen_lines(feed_string(VT.Terminal(4, 40), "ab\e[sc\e[uok"))[1] == "abok"
    end
    @testset "save and restore cursor (ESC 7, ESC 8)" begin
        @test VT.screen_lines(feed_string(VT.Terminal(4, 40), "ab\e7c\e8ok"))[1] == "abok"
    end
    @testset "cursor style (CSI 2 SP q)" begin
        t = feed_string(VT.Terminal(4, 40), "\e[2 qok")
        @test VT.screen_lines(t)[1] == "ok"
        @test VT.counters(t).ignored == Dict("CSI intermediate q" => 1)
    end
    @testset "xterm modifyOtherKeys (CSI > 4;1 m)" begin
        t = feed_string(VT.Terminal(4, 40), "\e[>4;1mok")
        @test VT.screen_lines(t)[1] == "ok"
        @test VT.counters(t).ignored == Dict("CSI > ... m" => 1)
    end
    @testset "device status report (CSI 6 n) is answered, not ignored" begin
        t = feed_string(VT.Terminal(4, 40), "\e[6nok")
        @test VT.screen_lines(t)[1] == "ok"
        @test VT.counters(t).ignored == Dict{String, Int}()
        @test VT.take_replies!(t) == Vector{UInt8}("\e[1;1R")
    end
    @testset "insert line" begin
        t = feed_string(VT.Terminal(4, 40), "a\r\nb\e[1;1H\e[Lok")
        @test VT.screen_lines(t)[1:3] == ["ok", "a", "b"]
    end
    @testset "delete character" begin
        @test VT.screen_lines(feed_string(VT.Terminal(4, 40), "abcd\e[1G\e[Pok"))[1] == "okd"
    end
    @testset "scroll up" begin
        t = feed_string(VT.Terminal(4, 40), "a\r\nb\e[Sok")
        @test VT.screen_lines(t)[1:2] == ["b", " ok"]
    end
    @testset "scroll margins outside the screen are ignored" begin
        t = feed_string(VT.Terminal(4, 40), "\e[2;5rok")
        @test VT.screen_lines(t)[1] == "ok"
        @test VT.counters(t).ignored == Dict("CSI r with invalid margins" => 1)
    end
    @testset "insert character" begin
        @test VT.screen_lines(feed_string(VT.Terminal(4, 40), "ab\e[1G\e[@ok"))[1] == "okb"
    end
    @testset "explicit zero parameter moves one row (CSI 0 B)" begin
        t = feed_string(VT.Terminal(4, 40), "a\e[0Bb")
        @test VT.screen_lines(t)[1:2] == ["a", " b"]
        @test VT.cursor_pos(t) == (2, 3)
    end
    @testset "256-colour foreground" begin
        t = feed_string(VT.Terminal(4, 40), "\e[38;5;196mA\e[48;2;1;2;3mB\e[0m")
        @test VT.screen_cell(t, 1, 1).style.fg == 196
        @test VT.screen_cell(t, 1, 2).style.fg == 196
        @test VT.screen_cell(t, 1, 2).style.bg == VT.RGB_FLAG | 0x010203
    end
    @testset "italic and strike" begin
        t = feed_string(VT.Terminal(4, 40), "\e[3;9mA\e[0m")
        attrs = VT.screen_cell(t, 1, 1).style.attrs
        @test (attrs & VT.ATTR_ITALIC) != 0
        @test (attrs & VT.ATTR_STRIKE) != 0
    end
    @testset "bracketed paste mode" begin
        t = feed_string(VT.Terminal(4, 40), "\e[?2004h\e[?2004lok")
        @test !t.bracketed_paste
        @test VT.screen_lines(t)[1] == "ok"
        @test isempty(VT.counters(t).ignored)
    end
    @testset "application cursor mode (DECCKM)" begin
        t = feed_string(VT.Terminal(4, 40), "\e[?1hok")
        @test VT.application_cursor(t)
        @test isempty(VT.counters(t).ignored)
        t = feed_string(t, "\e[?1l")
        @test !VT.application_cursor(t)
        @test isempty(VT.counters(t).ignored)
    end
    @testset "reset clears application cursor and bracketed paste modes" begin
        t = feed_string(VT.Terminal(4, 40), "\e[?1h\e[?2004h\ec")
        @test !VT.application_cursor(t)
        @test !VT.bracketed_paste(t)
    end
    @testset "cursor hide and show" begin
        t = feed_string(VT.Terminal(4, 40), "\e[?25l\e[?25hok")
        @test t.cursor_visible
        @test isempty(VT.counters(t).ignored)
    end
    @testset "two-byte UTF-8" begin
        @test VT.screen_lines(feed_string(VT.Terminal(4, 40), "é ok"))[1] == "é ok"
    end
end

@testset "resize" begin
    @testset "rows below the cursor are removed first" begin
        t = feed_string(VT.Terminal(5, 20), "ab")
        VT.resize_screen!(t, 3, 20)
        @test VT.screen_lines(t) == ["ab", "", ""]
        @test VT.cursor_pos(t) == (1, 3)
    end

    @testset "rows above the cursor leave the top" begin
        t = feed_string(VT.Terminal(5, 20), "\e[5;1Hxy")
        VT.resize_screen!(t, 2, 20)
        @test VT.screen_lines(t) == ["", "xy"]
        @test VT.cursor_pos(t) == (2, 3)
        # Rows that leave the top are appended, blank or not.
        @test [L.text for L in VT.take_lines!(t)] == ["", "", ""]
    end

    @testset "growing pads with blank rows and columns" begin
        t = feed_string(VT.Terminal(2, 5), "ab")
        VT.resize_screen!(t, 4, 8)
        @test length(VT.screen_lines(t)) == 4
        @test VT.screen_cell(t, 4, 8) == VT.BLANK_CELL
        @test VT.screen_lines(t)[1] == "ab"
    end

    @testset "text removed by narrowing is counted" begin
        t = feed_string(VT.Terminal(2, 10), "abcdefghij")
        VT.resize_screen!(t, 2, 4)
        @test VT.screen_lines(t)[1] == "abcd"
        @test VT.counters(t).discarded == 1
    end

    @testset "resizing while the alternate screen is active keeps the main screen" begin
        t = feed_string(VT.Terminal(4, 10), "x\e[?1049h")
        VT.resize_screen!(t, 6, 12)
        feed_string(t, "\e[?1049l")
        @test VT.screen_lines(t)[1] == "x"
        @test (t.rows, t.cols) == (6, 12)
        @test length(t.screen) == 6
    end

    @testset "shrinking while the alternate screen is active emits nothing; cut main rows are counted" begin
        t = feed_string(VT.Terminal(4, 10), "a\r\nb\r\nc\r\nd\e[?1049hxy")
        VT.resize_screen!(t, 2, 10)
        @test isempty(VT.take_lines!(t))
        @test VT.counters(t).discarded == 2
        feed_string(t, "\e[?1049l")
        @test VT.screen_lines(t)[1:2] == ["a", "b"]
    end

    @testset "invalid size" begin
        t = VT.Terminal(2, 2)
        @test_throws "at least 1 by 1" VT.resize_screen!(t, 0, 5)
        @test_throws "at least 1 by 1" VT.Terminal(3, 0)
    end
end

@testset "live row" begin
    t = feed_string(VT.Terminal(3, 20), "julia> ab")
    @test VT.live_line(t).text == "julia> ab"
    feed_string(t, "\r\n")
    @test VT.live_line(t) === nothing
end

# Feeds `pieces` in order, as separate calls to feed!.
function feed_pieces(t::VT.Terminal, pieces)
    for p in pieces
        VT.feed!(t, Vector{UInt8}(codeunits(p)), UInt64(1))
    end
    return t
end

# Replies taken from `t`, as a string.
replies(t::VT.Terminal) = String(VT.take_replies!(t))

@testset "terminal queries" begin
    @testset "device status report CSI 5 n" begin
        t = feed_string(VT.Terminal(4, 40), "\e[5n")
        @test replies(t) == "\e[0n"
        @test VT.counters(t).answered == Dict("CSI 5 n" => 1)
        @test isempty(VT.counters(t).ignored)
    end

    @testset "cursor position report CSI 6 n" begin
        @testset "at home" begin
            @test replies(feed_string(VT.Terminal(4, 40), "\e[6n")) == "\e[1;1R"
        end
        @testset "after text" begin
            @test replies(feed_string(VT.Terminal(4, 40), "abc\e[6n")) == "\e[1;4R"
        end
        @testset "after a wrap, the cursor waits in the last column until the next character" begin
            t = feed_string(VT.Terminal(4, 10), "0123456789\e[6n")
            @test replies(t) == "\e[1;10R"
            @test replies(feed_string(t, "X\e[6n")) == "\e[2;2R"
        end
        @testset "after cursor motion and a scroll" begin
            @test replies(feed_string(VT.Terminal(4, 40), "\e[3;5H\e[6n")) == "\e[3;5R"
            @test replies(feed_string(VT.Terminal(3, 10), "a\r\nb\r\nc\r\nd\e[6n")) == "\e[3;2R"
        end
        @testset "with a tall screen" begin
            @test replies(feed_string(VT.Terminal(100, 80), "\e[60;1H\e[6n")) == "\e[60;1R"
            @test replies(feed_string(VT.Terminal(100, 80), "\e[100;80H\e[6n")) == "\e[100;80R"
        end
        @testset "after a resize" begin
            t = VT.Terminal(4, 40)
            VT.resize_screen!(t, 30, 100)
            @test replies(feed_string(t, "\e[20;90H\e[6n")) == "\e[20;90R"
            t = feed_string(VT.Terminal(4, 40), "\e[4;30H")
            VT.resize_screen!(t, 3, 20)
            @test replies(feed_string(t, "\e[6n")) == "\e[3;20R"
        end
        @testset "reflects the cursor of the alternate screen while it is active" begin
            t = feed_string(VT.Terminal(6, 40), "ab\e[?1049h\e[3;4H\e[6n")
            @test replies(t) == "\e[3;4R"
            t = feed_string(t, "\e[?1049l\e[6n")
            @test replies(t) == "\e[1;3R"
        end
        @testset "the reply is the cursor at the query, for each query in one chunk" begin
            t = feed_string(VT.Terminal(4, 40), "abc\e[6ndef\e[6n")
            @test replies(t) == "\e[1;4R\e[1;7R"
        end
    end

    @testset "DEC cursor position report CSI ? 6 n" begin
        t = feed_string(VT.Terminal(4, 40), "abc\e[?6n")
        @test replies(t) == "\e[?1;4;1R"
        @test VT.counters(t).answered == Dict("CSI ? 6 n" => 1)
        @test isempty(VT.counters(t).ignored)
    end

    @testset "primary device attributes CSI c and CSI 0 c" begin
        t = feed_string(VT.Terminal(4, 40), "\e[c\e[0c")
        @test replies(t) == "\e[?1;2c\e[?1;2c"
        @test VT.counters(t).answered == Dict("CSI c" => 2)
        @test isempty(VT.counters(t).ignored)
    end

    @testset "screen size report CSI 18 t" begin
        t = VT.Terminal(24, 80)
        @test replies(feed_string(t, "\e[18t")) == "\e[8;24;80t"
        VT.resize_screen!(t, 40, 100)
        @test replies(feed_string(t, "\e[18t")) == "\e[8;40;100t"
        @test VT.counters(t).answered == Dict("CSI 18 t" => 2)
    end

    @testset "other queries are not answered and are counted as ignored" begin
        t = feed_string(VT.Terminal(4, 40), "\e[>c\e[>q\e[?2004\$p\e[14t\e]11;?\a\x05\e[7n\e[1c")
        @test isempty(VT.take_replies!(t))
        @test VT.counters(t).answered == Dict{String, Int}()
        @test VT.counters(t).ignored == Dict(
            "CSI > ... c" => 1, "CSI > ... q" => 1, "CSI ? ... p" => 1, "CSI t" => 1,
            "OSC" => 1, "C0 5" => 1, "CSI n" => 1, "CSI c" => 1)
    end

    @testset "chunk boundaries inside a query" begin
        t = feed_pieces(VT.Terminal(4, 40), ["abc\e", "[", "6", "n", "\e[?", "6", "n"])
        @test replies(t) == "\e[1;4R\e[?1;4;1R"
        @test VT.counters(t).answered == Dict("CSI 6 n" => 1, "CSI ? 6 n" => 1)
    end

    @testset "replies are the same for byte-at-a-time feeding" begin
        stream = "x\e[6n\e[5n\e[?6n\e[cabc\e[18t\e[14t\e[?2004\$p\e[>c\e[10;2H\e[6n"
        whole = feed_string(VT.Terminal(5, 30), stream)
        bytewise = VT.Terminal(5, 30)
        for b in codeunits(stream)
            VT.feed!(bytewise, [b], UInt64(1))
        end
        @test VT.take_replies!(bytewise) == VT.take_replies!(whole)
        @test VT.counters(bytewise) == VT.counters(whole)
    end

    @testset "take_replies! clears the replies" begin
        t = feed_string(VT.Terminal(4, 40), "\e[6n")
        @test replies(t) == "\e[1;1R"
        @test isempty(VT.take_replies!(t))
        @test VT.counters(t).answered == Dict("CSI 6 n" => 1)
    end
end
