const TALL_PM = MPIEnsemble.PaneModel
const TALL_LL = MPIEnsemble.LineLog
const TALL_VT = MPIEnsemble.VTParse
const TALL_PTY = MPIEnsemble.Pty

tall_bytes(s::AbstractString) = Vector{UInt8}(codeunits(s))

tall_plain(html::AbstractString) = rstrip(replace(replace(html, r"<[^>]*>" => ""), "&nbsp;" => " "))

@testset "tall_rows and MPIENSEMBLE_TALL_PTY_ROWS are validated before a window opens" begin
    for bad in (0, -3, 1.5, "200", true)
        @test_throws "tall_rows must be nothing or a positive integer" MPIEnsemble.run_single_repl(tall_rows = bad)
    end
    for bad in ("0", "-1", "x", "", "2.5")
        withenv("MPIENSEMBLE_TALL_PTY_ROWS" => bad) do
            @test_throws "MPIENSEMBLE_TALL_PTY_ROWS must be a positive integer" MPIEnsemble.main(String[])
        end
    end
    withenv("MPIENSEMBLE_TALL_PTY_ROWS" => "200") do
        @test MPIEnsemble.tall_rows_from_env() == 200
    end
    withenv("MPIENSEMBLE_TALL_PTY_ROWS" => nothing) do
        @test MPIEnsemble.tall_rows_from_env() === nothing
    end
end

@testset "tall screen: a 10-line input is on screen and not in the log" begin
    log = TALL_LL.RankLog(0)
    term = TALL_LL.begin_session!(log, 1, 200, 40)
    pane = TALL_PM.Pane(log, 200)
    TALL_PM.attach!(pane, term)
    input = ["julia> begin"; ["  x$i = $i" for i in 1:8]; "  end"]
    TALL_LL.feed_output!(log, term, tall_bytes(join(input, "\r\n")), 2)
    TALL_PM.refresh!(pane)
    @test length(log) == 0
    @test [rstrip(TALL_VT.screen_lines(term)[r]) for r in 1:10] == input
    @test TALL_PM.follow_row(pane) == 0
    @test tall_plain(pane.rows[TALL_PM.cursor_slot(pane)[1] - 1, 1]) == "  x8 = 8"

    # Up nine times moves the cursor to line 1, which the following pane then keeps in view.
    TALL_LL.feed_output!(log, term, tall_bytes("\e[9A\e[1G"), 3)
    TALL_PM.refresh!(pane)
    @test TALL_VT.cursor_pos(term) == (1, 1)
    slot = TALL_PM.follow_row(pane)
    @test slot > 0
    @test slot == TALL_PM.cursor_slot(pane)[1]

    # Editing line 1 changes the screen row, and the pane shows the edit; nothing is logged.
    TALL_LL.feed_output!(log, term, tall_bytes("ZZ"), 4)
    TALL_PM.refresh!(pane)
    @test occursin("ZZ", TALL_VT.screen_lines(term)[1])
    @test occursin("ZZ", pane.rows[slot, 1])
    @test length(log) == 0
    @test TALL_VT.counters(term).rewrites == 0
end

@testset "follow: a cursor row far above the end is placed in the matrix" begin
    log = TALL_LL.RankLog(0)
    term = TALL_LL.begin_session!(log, 1, 400, 40)
    pane = TALL_PM.Pane(log, 400)
    TALL_PM.attach!(pane, term)
    TALL_LL.feed_output!(log, term, tall_bytes(join(("line $i" for i in 1:300), "\r\n")), 2)
    TALL_LL.feed_output!(log, term, tall_bytes("\e[1;1H"), 3)
    TALL_PM.refresh!(pane)
    @test length(log) == 0
    @test pane.top == 1
    @test TALL_PM.follow_row(pane) == 1
    @test tall_plain(pane.rows[1, 1]) == "line 1"

    # Once the cursor is on the last text row, the pane follows the end again.
    TALL_LL.feed_output!(log, term, tall_bytes("\e[300;1H"), 4)
    TALL_PM.refresh!(pane)
    @test TALL_PM.follow_row(pane) == 0
end

@testset "follow: user scrolling stops following, typing resumes it" begin
    log = TALL_LL.RankLog(0)
    term = TALL_LL.begin_session!(log, 1, 200, 40)
    pane = TALL_PM.Pane(log, 200)
    TALL_PM.attach!(pane, term)
    TALL_LL.feed_output!(log, term, tall_bytes(join(("line $i" for i in 1:10), "\r\n")), 2)
    TALL_PM.refresh!(pane)
    TALL_PM.user_scrolled!(pane, 100, 6, false)
    @test !pane.follow
    @test TALL_PM.follow_row(pane) == 0
    TALL_PM.resume_following!(pane)
    @test pane.follow
    @test TALL_PM.follow_row(pane) == 0
end

@testset "tall pty: an edit to line 1 of a 10-line input stays on screen" begin
    cmd = Cmd(vcat(Base.julia_cmd().exec, ["-q", "--startup-file=no"]))
    s = TALL_PTY.spawn(cmd; rows = 200, cols = 80)
    ch = Channel{Vector{UInt8}}(Inf)
    reader = @async begin
        try
            while true
                b = readavailable(s)
                isempty(b) && break
                put!(ch, b)
            end
        catch err
            # Reading a pseudo-terminal after its child exits fails with EIO.
            err isa Base.IOError || rethrow()
        finally
            close(ch)
        end
    end
    log = TALL_LL.RankLog(0)
    term = TALL_LL.begin_session!(log, time_ns(), 200, 80)
    pane = TALL_PM.Pane(log, 200)
    TALL_PM.attach!(pane, term)

    # Feeds the output received so far to the log, refreshing the pane, until `done()` holds.
    function wait_until(done, what; timeout = 60)
        deadline = time() + timeout
        while true
            while isready(ch)
                TALL_LL.feed_output!(log, term, take!(ch), time_ns())
            end
            TALL_PM.refresh!(pane)
            done() && return nothing
            time() > deadline && error("timed out waiting for $what; screen: $(TALL_VT.screen_lines(term))")
            sleep(0.02)
        end
    end
    # Input is sent as the window sends it: the pane resumes following, then the bytes are written.
    function send(bytes)
        wait_until(() -> TALL_PTY.is_raw(s), "the REPL to read keystrokes")
        TALL_PM.resume_following!(pane)
        write(s, bytes)
    end
    cursor_row() = TALL_VT.cursor_pos(term)[1]

    try
        wait_until(() -> any(l -> occursin("julia>", l), TALL_VT.screen_lines(term)), "the prompt")
        @test cursor_row() == 1
        send("begin\n")
        wait_until(() -> cursor_row() == 2, "the second line of input")
        for i in 1:8
            send("x$i = $i\n")
            wait_until(() -> cursor_row() == i + 2, "line $(i + 2) of input")
        end
        send("end")
        wait_until(() -> strip(TALL_VT.screen_lines(term)[10]) == "end", "end on line 10")
        @test length(log) == 0
        for k in 1:9
            send("\e[A")
            wait_until(() -> cursor_row() == 10 - k, "the cursor on line $(10 - k)")
        end
        send("ZZ")
        wait_until(() -> occursin("ZZ", TALL_VT.screen_lines(term)[1]), "the edit on line 1")
        @test occursin("ZZ", TALL_VT.screen_lines(term)[1])
        @test length(log) == 0
        @test TALL_VT.counters(term).rewrites == 0
        slot = TALL_PM.follow_row(pane)
        @test slot > 0
        @test occursin("ZZ", pane.rows[slot, 1])
    finally
        close(s)
        wait(reader)
    end
end

@testset "tall pty: displaysize reports the tall row count" begin
    cmd = Cmd(vcat(Base.julia_cmd().exec, ["-q", "--startup-file=no"]))
    s = TALL_PTY.spawn(cmd; rows = 200, cols = 80)
    ch = Channel{Vector{UInt8}}(Inf)
    reader = @async begin
        try
            while true
                b = readavailable(s)
                isempty(b) && break
                put!(ch, b)
            end
        catch err
            err isa Base.IOError || rethrow()
        finally
            close(ch)
        end
    end
    term = TALL_VT.Terminal(200, 80)
    try
        deadline = time() + 60
        function pump_until(done)
            while !done()
                time() > deadline && error("timed out; screen: $(TALL_VT.screen_lines(term))")
                isready(ch) ? TALL_VT.feed!(term, take!(ch)) : sleep(0.02)
            end
        end
        pump_until(() -> any(l -> occursin("julia>", l), TALL_VT.screen_lines(term)))
        write(s, "displaysize(stdout)\n")
        pump_until(() -> any(l -> occursin("(200, 80)", l), TALL_VT.screen_lines(term)))
        @test any(l -> occursin("(200, 80)", l), TALL_VT.screen_lines(term))
    finally
        close(s)
        wait(reader)
    end
end
