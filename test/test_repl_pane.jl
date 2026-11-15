# Tabs as headless sessions: each tab's ReplPane.State owns a real child, a log and a pane, and a
# hidden tab's child is still read. These tests do not need a display.
const RP = MPIEnsemble.ReplPane
const RP_LL = MPIEnsemble.LineLog
const RP_VT = MPIEnsemble.VTParse

# A tab whose child runs `command`, sized 24 by 80 and started (see `ReplPane.size!`).
function rp_tab(command::Cmd; changed = () -> nothing)
    st = RP.State(command, "", nothing; changed)
    RP.size!(st, 24, 80)
    return st
end

rp_shell(script::AbstractString) = Cmd(["sh", "-c", script])

# Feed the tab's output until `done(st)` holds. Fails on a deadline, so that a tab that never gets
# there shows up as an error rather than a hang.
function rp_feed_until(done, st; timeout::Real = 30)
    deadline = time() + timeout
    while !done(st)
        time() < deadline || error("timed out after $timeout s")
        RP.feed!(st, 500)
        sleep(0.002)
    end
    return st
end

# Lines of the log, and of the screen, which holds the lines that have not scrolled off yet.
# Pane rows are HTML, with spaces written as `&nbsp;`.
rp_plain(row) = replace(replace(row, r"<[^>]*>" => ""), "&nbsp;" => " ")

rp_lines(st) = [e.text for e in RP_LL.window(st.log, 1:length(st.log)) if e.kind === :line]
rp_screen(st) = [rstrip(l) for l in RP_VT.screen_lines(st.repl.term)]

# Values of the lines `key=[value]` that the child has written, from the log and the screen.
function rp_values(st, key)
    re = Regex("^$key=\\[(.*)\\]\$")
    found = String[]
    for l in vcat(rp_lines(st), rp_screen(st))
        m = match(re, l)
        m === nothing || push!(found, m.captures[1])
    end
    return unique(found)
end

@testset "tabs: a variable set in one session is not visible in another" begin
    # Each session is a shell that evaluates the lines it reads, so shell variables persist within a
    # session only. Each session writes its answers to its own log.
    loop = "while IFS= read -r l; do eval \"\$l\"; done"
    tabs = [rp_tab(rp_shell(loop)) for _ in 1:3]
    try
        RP.feed!(tabs[1], 500)
        RP.send_input!(tabs[1], Vector{UInt8}("x=one; echo \"x=[\$x]\"\n"))
        RP.send_input!(tabs[2], Vector{UInt8}("x=two; echo \"x=[\$x]\"\n"))
        RP.send_input!(tabs[3], Vector{UInt8}("echo \"x=[\$x]\"\n"))
        for st in tabs
            rp_feed_until(s -> length(rp_values(s, "x")) >= 1, st)
        end
        @test rp_values(tabs[1], "x") == ["one"]
        @test rp_values(tabs[2], "x") == ["two"]
        @test rp_values(tabs[3], "x") == [""]
    finally
        foreach(RP.shutdown!, tabs)
    end
end

@testset "tabs: closing one session leaves the others running" begin
    # `cat` runs until its input is closed, so each session stays open until it is shut down.
    tabs = [rp_tab(Cmd(["cat"])) for _ in 1:3]
    pids = [getpid(st.repl.session.process) for st in tabs]
    try
        RP.shutdown!(tabs[2])
        @test !ispath("/proc/$(pids[2])")
        @test process_running(tabs[1].repl.session.process)
        @test process_running(tabs[3].repl.session.process)
        @test ispath("/proc/$(pids[1])") && ispath("/proc/$(pids[3])")
    finally
        foreach(RP.shutdown!, tabs)
    end
    @test all(!ispath("/proc/$pid") for pid in pids)
end

@testset "tabs: a hidden tab's output is read and logged, and its pane is not refilled" begin
    refills = Ref(0)
    st = rp_tab(rp_shell("seq 1 3000; cat"); changed = () -> refills[] += 1)
    try
        @test !st.visible
        refills[] = 0
        # The last rows stay on the 24-row screen, so the log has about 2980 of the 3000 lines.
        rp_feed_until(s -> length(s.log) >= 2900, st)
        @test refills[] == 0
        @test length(st.log) >= 2900

        RP.set_visible!(st, true)
        @test refills[] >= 1
        @test any(row -> occursin("3000", row), st.pane.rows)
    finally
        RP.shutdown!(st)
    end
end

@testset "tabs: a visible tab's output refills its pane" begin
    refills = Ref(0)
    st = rp_tab(rp_shell("echo first; cat"); changed = () -> refills[] += 1)
    try
        RP.set_visible!(st, true)
        refills[] = 0
        rp_feed_until(s -> any(l -> occursin("first", l), rp_screen(s)), st)
        @test refills[] >= 1
        @test any(row -> occursin("first", row), st.pane.rows)
    finally
        RP.shutdown!(st)
    end
end

@testset "tabs: ten open and close cycles leave no processes and no descriptors" begin
    # `cat` exits when its input is closed, so that closing each session takes no timeout.
    fds() = length(readdir("/proc/self/fd"))
    cycle() = rp_tab(Cmd(["cat"]))
    RP.shutdown!(cycle())
    before = fds()
    pids = Int[]
    for _ in 1:10
        st = cycle()
        push!(pids, getpid(st.repl.session.process))
        RP.shutdown!(st)
    end
    @test fds() == before
    @test all(!ispath("/proc/$pid") for pid in pids)
end

# A session that ends leaves its output in the pane, whether the tab was visible or hidden at the end.
@testset "tabs: output of a session that ends stays in the pane, visible or hidden at the end" begin
    for visible_at_end in (true, false)
        st = rp_tab(rp_shell("seq 1 60 | sed \"s/^/line /\"; exit 0"))
        try
            RP.set_visible!(st, visible_at_end)
            rp_feed_until(s -> MPIEnsemble.ReplSession.has_ended(s.repl), st)
            @test "line 1" in rp_lines(st)
            RP.set_visible!(st, true)
            text = [rp_plain(row) for row in st.pane.rows]
            @test "line 60" in text
            @test "line 1" in text
        finally
            RP.shutdown!(st)
        end
    end
end

@testset "tabs: a tab can be shown before it is sized, and then sized and fed" begin
    refills = Ref(0)
    st = RP.State(rp_shell("echo first; cat"), "", nothing; changed = () -> refills[] += 1)
    try
        RP.set_visible!(st, true)
        @test st.visible
        @test refills[] >= 1
        RP.size!(st, 24, 80)
        rp_feed_until(s -> any(l -> occursin("first", l), rp_screen(s)), st)
        @test any(row -> occursin("first", row), st.pane.rows)
    finally
        RP.shutdown!(st)
    end
end

# The Gui module, loaded on first use. Its window state and tab functions do not need a QML engine.
# Loading QML creates a QGuiApplication, which needs a Qt platform plugin; the offscreen plugin does not
# need a display. The variable is set only while QML loads, as Qt reads it at that point. Bound at top
# level, so that its methods are visible to the test blocks that follow.
withenv("QT_QPA_PLATFORM" => "offscreen") do
    MPIEnsemble.gui_function(:run_single_repl)
end
const RP_GUI = Base.invokelatest(getfield, MPIEnsemble, :Gui)

@testset "window: a new tab is shown and selected before its pane is sized" begin
    win = RP_GUI.WindowState("", nothing, nothing)
    try
        RP_GUI.new_tab!(win)
        tab = only(win.tabs.tabs)
        view = tab.state
        @test win.views[view.id] === view
        @test view.session.visible
        @test !MPIEnsemble.ReplSession.is_started(view.session.repl)
        @test win.tabs.selected == tab.id
        @test win.props["selected"] == tab.id
    finally
        RP_GUI.shutdown!(win)
    end
end

@testset "window: the startup input goes to the first tab only" begin
    win = RP_GUI.WindowState("println(1)\r", nothing, nothing)
    try
        RP_GUI.new_tab!(win)
        RP_GUI.new_tab!(win)
        first, second = [t.state for t in win.tabs.tabs]
        @test first.session.startup_input == "println(1)\r"
        @test second.session.startup_input == ""
        @test !win.startup_pending
    finally
        RP_GUI.shutdown!(win)
    end
end

@testset "window: a tab whose REPL fails to end is removed, the error propagates, and shutdown is not repeated" begin
    win = RP_GUI.WindowState("", nothing, nothing)
    RP_GUI.new_tab!(win)
    RP_GUI.new_tab!(win)
    kept_id, failing_id = [t.id for t in win.tabs.tabs]
    failing_pane = win.tabs.tabs[2].state.id
    win.views[failing_pane].session.repl.writer_error[] = ErrorException("injected writer failure")
    err = try
        RP_GUI.close_tab!(win, failing_id)
        nothing
    catch e
        e
    end
    @test err isa ErrorException && occursin("injected writer failure", err.msg)
    @test !MPIEnsemble.TabSet.is_open(win.tabs, failing_id)
    @test !haskey(win.views, failing_pane)
    @test [t.id for t in win.tabs.tabs] == [kept_id]
    @test RP_GUI.shutdown!(win) === nothing
end

@testset "window: an event for a hidden pane is an error, except a scroll or size event" begin
    win = RP_GUI.WindowState("", nothing, nothing)
    try
        RP_GUI.new_tab!(win)
        RP_GUI.new_tab!(win)
        hidden_id, shown_id = [t.state.id for t in win.tabs.tabs]
        @test !win.views[hidden_id].session.visible
        @test win.views[shown_id].session.visible

        # Scroll and size events return their default, and record no failure.
        @test RP_GUI.pane_call(_ -> error("not run"), win, hidden_id, 0; hidden_ok = true) == 0
        @test win.failure === nothing

        # Any other event records a failure, which the event loop rethrows.
        @test RP_GUI.pane_call(_ -> "ran", win, hidden_id, false) === false
        @test win.failure !== nothing
        err = try
            RP_GUI.check_failure!(win)
            nothing
        catch e
            e
        end
        @test occursin("whose pane is hidden", sprint(showerror, err))

        win.failure = nothing
        @test RP_GUI.pane_call(_ -> "ran", win, shown_id, false) == "ran"
        @test win.failure === nothing
    finally
        RP_GUI.shutdown!(win)
    end
end
