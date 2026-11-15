# The MPI tab of the window (Gui.jl), driven without QML: the window's event loop is `Gui.service!`, and
# the rank panes are the window's `TabView`s. The ranks are started by the fake launcher
# (test/mpi/fake_mpiexec.sh) with the fake wrapper (test/mpi/fake_wrapper.py), so no julia runs in a rank,
# except for the one test that checks the REPL tab after a failed launch. The fake wrapper's mode is set
# with FAKE_WRAPPER_MODE, which applies to every rank, or to one rank as MODE@RANK. These tests need sh and
# setsid, and no display; the wrapper runs with the Python from Python_jll.

# Loading QML creates a QGuiApplication, which needs a Qt platform plugin; the offscreen one does not need
# a display (see test_repl_pane.jl).
withenv("QT_QPA_PLATFORM" => "offscreen") do
    MPIEnsemble.gui_function(:run_single_repl)
end
const MT_GUI = Base.invokelatest(getfield, MPIEnsemble, :Gui)
const MT_VT = MPIEnsemble.VTParse
const MT_LL = MPIEnsemble.LineLog
const MT_ReplSession = MPIEnsemble.ReplSession

const MT_FAKE_LAUNCHER = Cmd(["sh", joinpath(@__DIR__, "mpi", "fake_mpiexec.sh")])
const MT_FAKE_WRAPPER = joinpath(@__DIR__, "mpi", "fake_wrapper.py")
const MT_TIMEOUT = 60
const MT_OPTIONS = (launcher = MT_FAKE_LAUNCHER, wrapper = MT_FAKE_WRAPPER, timeout = MT_TIMEOUT)

# Run `f` with XDG_RUNTIME_DIR set, which the launcher needs, and with the fake wrapper in `mode`.
mt_with(f; mode::AbstractString = "echo") =
    withenv(f, "XDG_RUNTIME_DIR" => get(ENV, "XDG_RUNTIME_DIR", tempdir()), "FAKE_WRAPPER_MODE" => mode)

mt_mpi(win) = only(t.state for t in win.tabs.tabs if t.kind === :mpi)
mt_rank_panes(win) = Base.values(win.rank_panes)[]

# Drive the window's event loop until `done()` holds. A failure of the window is thrown, as the loop does.
# Fails after `timeout` seconds, so that a hang shows up as an error.
function mt_run_until(done, win; timeout::Real = MT_TIMEOUT)
    deadline = time() + timeout
    while !done()
        time() < deadline || error("timed out after $timeout s")
        MT_GUI.check_failure!(win)
        MT_GUI.service!(win)
        sleep(0.005)
    end
    return nothing
end

# Size every rank pane, as QML does when it shows them: 400 by 800 pixels is 25 rows of 100 columns for a
# cell of 16 by 8 pixels.
mt_size!(win; width = 800, height = 400) =
    foreach(v -> MT_GUI.pane_sized!(v, width, height, 8, 16), mt_mpi(win).views)

# The text of a pane: its log lines, then the lines of its screen.
mt_text(view) = join(vcat([e.text for e in MT_LL.window(view.session.log, 1:length(view.session.log))],
    [rstrip(l) for l in MT_VT.screen_lines(view.session.repl.term)]), "\n")

# Processes of the fake launcher and of the fake wrappers, found by their command lines. The check covers
# all of them, not only the ones that a test started, so it needs no other fake job to be running.
function mt_fake_processes()
    found = Int[]
    for entry in readdir("/proc")
        all(isdigit, entry) || continue
        cmdline = try
            read("/proc/$entry/cmdline", String)
        catch
            continue
        end
        (occursin("fake_wrapper.py", cmdline) || occursin("fake_mpiexec.sh", cmdline)) && push!(found, parse(Int, entry))
    end
    return found
end

# Whether the fake processes are all gone within `timeout` seconds.
mt_fake_processes_gone(; timeout = 10) = timedwait(() -> isempty(mt_fake_processes()), timeout; pollint = 0.05) === :ok

# Whether a process with `pid` still exists, as a zombie or not.
mt_exists(pid::Integer) = ccall(:kill, Cint, (Cint, Cint), pid, 0) == 0

@testset "MPI tab: the grid has ceil(sqrt(N)) columns" begin
    @test [MT_GUI.rank_columns(n) for n in 1:10] == [1, 2, 2, 2, 3, 3, 3, 3, 3, 4]
    for n in (1, 2, 3, 4, 5, 9)
        @test MT_GUI.rank_columns(n) == ceil(Int, sqrt(n))
    end
    @test_throws MethodError MT_GUI.rank_columns(1.5)
end

@testset "MPI tab: the ranks start in a task, with one pane per rank in rank order" begin
    for n in (1, 2, 3, 4, 5, 9)
        mt_with() do
            win = MT_GUI.WindowState("", nothing, n; launch_options = MT_OPTIONS)
            try
                MT_GUI.new_tab!(win)
                tab = MT_GUI.open_mpi_tab!(win)
                mpi = tab.state
                # The tab is open and selected at once, and says that the ranks are starting.
                @test [t.kind for t in win.tabs.tabs] == [:repl, :mpi]
                @test MPIEnsemble.TabSet.tab_title(tab) == "MPI"
                @test win.props["selected"] == tab.id
                @test win.props["selectedKind"] == "mpi"
                @test win.props["selectedPane"] == 0
                @test mpi.status === :starting
                @test win.mpi_props["status"] == "starting"
                @test win.mpi_props["message"] == "Starting $n MPI ranks…"
                @test isempty(mt_rank_panes(win))
                mt_run_until(() -> mpi.status !== :starting, win)
                @test mpi.status === :running
                @test mpi.failure === nothing
                @test win.mpi_props["status"] == "running"
                @test [v.rank for v in mpi.views] == collect(0:n - 1)
                @test length(mt_rank_panes(win)) == n
                @test [v.id for v in mt_rank_panes(win)] == [v.id for v in mpi.views]
                @test all(v.session.visible for v in mpi.views)
                @test all(v -> v.rank !== nothing, mpi.views)
                @test win.mpi_props["columns"] == ceil(Int, sqrt(n))
                # The REPL tab is not affected: its pane is still there, and hidden.
                repl = win.tabs.tabs[1].state
                @test !repl.session.visible
                @test win.views[repl.id] === repl
                pids = [v.session.repl.source.connection.pid for v in mpi.views]
                pane_ids = [v.id for v in mpi.views]
                job_process = mpi.job.process
                MT_GUI.close_tab!(win, tab.id)
                @test all(!haskey(win.views, id) for id in pane_ids)
                @test isempty(mt_rank_panes(win))
                @test process_exited(job_process)
                @test timedwait(() -> all(!mt_exists(p) for p in pids), 10; pollint = 0.05) === :ok
                @test mt_fake_processes_gone()
            finally
                MT_GUI.shutdown!(win)
            end
        end
    end
end

@testset "MPI tab: pane ids are unique, and a REPL tab's pane is not its tab" begin
    mt_with() do
        win = MT_GUI.WindowState("", nothing, 3; launch_options = MT_OPTIONS)
        try
            MT_GUI.new_tab!(win)
            MT_GUI.new_tab!(win)
            MT_GUI.open_mpi_tab!(win)
            mpi = mt_mpi(win)
            mt_run_until(() -> mpi.status !== :starting, win)
            @test length(win.views) == 5
            @test sort(collect(keys(win.views))) == collect(1:5)
            @test all(win.views[id].id == id for id in keys(win.views))
            repl_ids = [t.state.id for t in win.tabs.tabs if t.kind === :repl]
            @test repl_ids == [1, 2]
            @test [v.id for v in mpi.views] == [3, 4, 5]
        finally
            MT_GUI.shutdown!(win)
        end
    end
end

@testset "MPI tab: the rank panes are shown only while the tab is selected" begin
    mt_with() do
        win = MT_GUI.WindowState("", nothing, 2; launch_options = MT_OPTIONS)
        try
            MT_GUI.new_tab!(win)
            repl_tab = win.tabs.tabs[1]
            tab = MT_GUI.open_mpi_tab!(win)
            mpi = tab.state
            mt_run_until(() -> mpi.status !== :starting, win)
            rank_id = mpi.views[1].id
            @test MT_GUI.pane_call(v -> v.id, win, rank_id, 0) == rank_id

            # Selecting the REPL tab hides the rank panes: an event for one of them is then an error,
            # except a size or scroll event, which returns the default.
            MT_GUI.select_tab!(win, repl_tab.id)
            @test !mpi.views[1].session.visible
            @test win.props["selectedKind"] == "repl"
            @test win.props["selectedPane"] == repl_tab.state.id
            @test MT_GUI.pane_call(_ -> error("not run"), win, rank_id, 0; hidden_ok = true) == 0
            @test win.failure === nothing
            @test MT_GUI.pane_call(_ -> "ran", win, rank_id, false) === false
            @test win.failure !== nothing
            @test_throws "whose pane is hidden" MT_GUI.check_failure!(win)
            win.failure = nothing

            MT_GUI.select_tab!(win, tab.id)
            @test all(v.session.visible for v in mpi.views)
            @test MT_GUI.pane_call(_ -> "ran", win, rank_id, false) == "ran"
            @test win.failure === nothing
        finally
            MT_GUI.shutdown!(win)
        end
    end
end

@testset "MPI tab: input to one pane reaches only that rank" begin
    mt_with() do
        win = MT_GUI.WindowState("", nothing, 3; launch_options = MT_OPTIONS)
        try
            MT_GUI.open_mpi_tab!(win)
            mpi = mt_mpi(win)
            mt_run_until(() -> mpi.status !== :starting, win)
            mt_size!(win)
            mt_run_until(() -> all(occursin("resize 25 100", mt_text(v)) for v in mpi.views), win)

            target = mpi.views[2]
            # Each rank's wrapper echoes what it receives, so the marker shows in the pane of that rank only.
            @test MT_GUI.send_bytes!(target, Vector{UInt8}(codeunits("marker-one"))) === true
            mt_run_until(() -> occursin("marker-one", mt_text(target)), win)
            for other in mpi.views
                other === target && continue
                @test !occursin("marker-one", mt_text(other))
            end
        finally
            MT_GUI.shutdown!(win)
        end
    end
end

# Whether every pane of `views` shows `text`.
mt_all_show(views, text) = all(occursin(text, mt_text(v)) for v in views)

@testset "MPI tab: input to the focused rank pane reaches every rank" begin
    mt_with() do
        win = MT_GUI.WindowState("", nothing, 3; launch_options = MT_OPTIONS)
        try
            MT_GUI.open_mpi_tab!(win)
            mpi = mt_mpi(win)
            @test isempty(mpi.targets)
            mt_run_until(() -> mpi.status !== :starting, win)
            mt_size!(win)
            mt_run_until(() -> all(occursin("resize 25 100", mt_text(v)) for v in mpi.views), win)
            @test mpi.targets == Set(0:2)
            @test mpi.zoomed === nothing
            @test [v.rank for v in MT_GUI.route_targets(mpi)] == [0, 1, 2]

            # A key typed in rank 0's pane is echoed by every rank, and the focused pane reports it was sent.
            @test MT_GUI.key_input!(win, mpi.views[1], 0, "key-all", 0) === true
            mt_run_until(() -> mt_all_show(mpi.views, "key-all"), win)
            # The same for a paste, from the pane of rank 2.
            @test MT_GUI.paste_input!(win, mpi.views[3], "paste-all") === true
            mt_run_until(() -> mt_all_show(mpi.views, "paste-all"), win)
        finally
            MT_GUI.shutdown!(win)
        end
    end
end

@testset "MPI tab: a zoomed rank alone receives input" begin
    mt_with() do
        win = MT_GUI.WindowState("", nothing, 3; launch_options = MT_OPTIONS)
        try
            MT_GUI.open_mpi_tab!(win)
            mpi = mt_mpi(win)
            mt_run_until(() -> mpi.status !== :starting, win)
            mt_size!(win)
            mt_run_until(() -> all(occursin("resize 25 100", mt_text(v)) for v in mpi.views), win)

            mpi.zoomed = 1
            @test [v.rank for v in MT_GUI.route_targets(mpi)] == [1]
            # A key from rank 0's pane goes to the zoomed rank 1, and rank 0 does not handle it.
            @test MT_GUI.key_input!(win, mpi.views[1], 0, "from-zero", 0) === false
            @test MT_GUI.key_input!(win, mpi.views[2], 0, "zoom-one", 0) === true
            mt_run_until(() -> occursin("from-zero", mt_text(mpi.views[2])) &&
                occursin("zoom-one", mt_text(mpi.views[2])), win)

            # Input sent to a rank is echoed in the order it was sent, so once "after-zoom" has reached every
            # rank, any earlier input sent to that rank has been echoed too.
            mpi.zoomed = nothing
            @test MT_GUI.key_input!(win, mpi.views[1], 0, "after-zoom", 0) === true
            mt_run_until(() -> mt_all_show(mpi.views, "after-zoom"), win)
            @test !occursin("from-zero", mt_text(mpi.views[1]))
            @test !occursin("zoom-one", mt_text(mpi.views[1]))
            @test !occursin("from-zero", mt_text(mpi.views[3]))
            @test !occursin("zoom-one", mt_text(mpi.views[3]))

            # A zoomed rank without a pane is an error.
            mpi.zoomed = 7
            @test_throws "zoomed rank 7 has no pane" MT_GUI.route_targets(mpi)
            mpi.zoomed = nothing
        finally
            MT_GUI.shutdown!(win)
        end
    end
end

@testset "MPI tab: only the ranks in targets receive input" begin
    mt_with() do
        win = MT_GUI.WindowState("", nothing, 3; launch_options = MT_OPTIONS)
        try
            MT_GUI.open_mpi_tab!(win)
            mpi = mt_mpi(win)
            mt_run_until(() -> mpi.status !== :starting, win)
            mt_size!(win)
            mt_run_until(() -> all(occursin("resize 25 100", mt_text(v)) for v in mpi.views), win)

            mpi.targets = Set([0, 2])
            @test [v.rank for v in MT_GUI.route_targets(mpi)] == [0, 2]
            @test MT_GUI.key_input!(win, mpi.views[1], 0, "subset-zero", 0) === true
            mt_run_until(() -> occursin("subset-zero", mt_text(mpi.views[1])) &&
                occursin("subset-zero", mt_text(mpi.views[3])), win)
            # A key from rank 1's pane, which is not a target, goes to the targets. Rank 1 does not handle
            # it, so the result is false.
            @test MT_GUI.key_input!(win, mpi.views[2], 0, "subset-one", 0) === false
            mt_run_until(() -> occursin("subset-one", mt_text(mpi.views[1])) &&
                occursin("subset-one", mt_text(mpi.views[3])), win)
            @test !occursin("subset-one", mt_text(mpi.views[2]))

            # A target without a pane is an error, not a silent skip.
            mpi.targets = Set([0, 5])
            @test_throws "a target rank of this MPI tab has no pane" MT_GUI.route_targets(mpi)
            mpi.targets = Set(0:2)

            # Every rank is a target again. "subset-all" reaches every rank, and the earlier input has been
            # echoed in each rank before it.
            @test MT_GUI.key_input!(win, mpi.views[1], 0, "subset-all", 0) === true
            mt_run_until(() -> mt_all_show(mpi.views, "subset-all"), win)
            @test !occursin("subset-one", mt_text(mpi.views[2]))
            @test !occursin("subset-zero", mt_text(mpi.views[2]))
        finally
            MT_GUI.shutdown!(win)
        end
    end
end

@testset "REPL tab: key presses and pastes reach only its own pane" begin
    mt_with() do
        win = MT_GUI.WindowState("", nothing, 2; launch_options = MT_OPTIONS)
        try
            MT_GUI.new_tab!(win)
            MT_GUI.open_mpi_tab!(win)
            mpi = mt_mpi(win)
            mt_run_until(() -> mpi.status !== :starting, win)
            mt_size!(win)
            repl = win.tabs.tabs[1].state
            MT_GUI.pane_sized!(repl, 400, 800, 8, 16)
            @test MT_ReplSession.is_started(repl.session.repl)
            @test MT_GUI.mpi_tab_of(win, repl) === nothing

            # The REPL's key goes to its pane only, and the Julia REPL there evaluates it.
            key_return = 0x01000004
            @test MT_GUI.key_input!(win, repl, 0, "println(2*21)", 0) === true
            @test MT_GUI.key_input!(win, repl, key_return, "", 0) === true
            mt_run_until(() -> any(occursin("42", l) for l in MT_VT.screen_lines(repl.session.repl.term)), win)
            @test all(!occursin("println", mt_text(v)) for v in mpi.views)
            @test MT_GUI.paste_input!(win, repl, "") === false
        finally
            MT_GUI.shutdown!(win)
        end
    end
end

@testset "MPI tab: a pane is resized only when its size in rows or columns changes" begin
    mt_with() do
        win = MT_GUI.WindowState("", nothing, 2; launch_options = MT_OPTIONS)
        try
            MT_GUI.open_mpi_tab!(win)
            mpi = mt_mpi(win)
            mt_run_until(() -> mpi.status !== :starting, win)
            # The launch set 24 by 80, and the first size of each pane replaces it. The echo wrapper writes each
            # RESIZE it receives as a line, and its output is read once the pane has been sized.
            mt_size!(win)
            mt_run_until(() -> all(occursin("resize 25 100", mt_text(v)) for v in mpi.views), win)
            count_lines(v, text) = count(l -> occursin(text, l), split(mt_text(v), "\n"))
            @test all(count_lines(v, "resize 24 80") == 1 for v in mpi.views)
            @test all(count_lines(v, "resize 25 100") == 1 for v in mpi.views)

            # A change of pixels that leaves rows and columns alone sends nothing.
            mt_size!(win; width = 805, height = 405)
            for _ in 1:20
                MT_GUI.service!(win)
                sleep(0.01)
            end
            @test all(count_lines(v, "resize 25 100") == 1 for v in mpi.views)
            @test all(v.session.repl.rows == 25 && v.session.repl.cols == 100 for v in mpi.views)

            # A change of columns sends a RESIZE to the rank whose pane changed, and to no other rank.
            mt_size!(win; width = 1000)
            mt_run_until(() -> all(occursin("resize 25 125", mt_text(v)) for v in mpi.views), win)
            @test all(count_lines(v, "resize 25 125") == 1 for v in mpi.views)
            @test all(count_lines(v, "resize 25 100") == 1 for v in mpi.views)
        finally
            MT_GUI.shutdown!(win)
        end
    end
end

@testset "MPI tab: a rank's exit shows its exit code in its pane, without a restart" begin
    mt_with(mode = "exit_frame") do
        win = MT_GUI.WindowState("", nothing, 2; launch_options = MT_OPTIONS)
        try
            MT_GUI.open_mpi_tab!(win)
            mpi = mt_mpi(win)
            mt_run_until(() -> mpi.status !== :starting, win)
            mt_size!(win)
            mt_run_until(() -> all(MT_ReplSession.has_ended(v.session.repl) for v in mpi.views), win)
            for view in mpi.views
                @test view.session.repl.exit == MT_ReplSession.ExitInfo(7, 0)
                @test view.props["ended"] == true
                @test view.props["exitText"] ==
                    "Rank $(view.rank) ended: Julia exited with code 7. Restarting needs the whole MPI job to restart."
                @test view.failure === nothing
                # A rank cannot be restarted: its session refuses, and the window does not offer it.
                @test view.rank !== nothing
                @test_throws "cannot be restarted" MPIEnsemble.ReplPane.restart!(view.session)
            end
            @test win.failure === nothing
            @test MT_GUI.end_text(mpi.views[1]) == "Rank 0 ended: Julia exited with code 7. " *
                "Restarting needs the whole MPI job to restart."
        finally
            MT_GUI.shutdown!(win)
        end
    end
end

@testset "MPI tab: a rank whose connection closes without an EXIT frame fails its pane only" begin
    mt_with(mode = "no_exit@1") do
        win = MT_GUI.WindowState("", nothing, 3; launch_options = MT_OPTIONS)
        try
            MT_GUI.open_mpi_tab!(win)
            mpi = mt_mpi(win)
            mt_run_until(() -> mpi.status !== :starting, win)
            mt_size!(win)
            failing = only(v for v in mpi.views if v.rank == 1)
            others = [v for v in mpi.views if v.rank != 1]
            mt_run_until(() -> failing.failure !== nothing, win)

            @test occursin("closed its socket without an EXIT frame", sprint(showerror, failing.failure))
            @test failing.props["ended"] == true
            @test failing.props["exitText"] == "Rank 1 failed: " * sprint(showerror, failing.failure)
            @test !MT_ReplSession.has_ended(failing.session.repl)
            # The window keeps running, and the other ranks keep working.
            @test win.failure === nothing
            @test MT_GUI.send_bytes!(failing, Vector{UInt8}(codeunits("lost"))) === false
            for view in others
                @test view.failure === nothing
                @test view.props["ended"] == false
            end
            @test MT_GUI.send_bytes!(others[1], Vector{UInt8}(codeunits("still-here"))) === true
            mt_run_until(() -> occursin("still-here", mt_text(others[1])), win)
            @test !occursin("still-here", mt_text(failing))

            # Closing the tab shuts the job down, and the failure, which the pane already showed, is not
            # thrown again.
            MT_GUI.close_tab!(win, win.tabs.tabs[1].id)
            @test isempty(win.tabs.tabs)
            @test mt_fake_processes_gone()
        finally
            MT_GUI.shutdown!(win)
        end
    end
end

@testset "MPI tab: a launch that fails leaves an error in the tab, and the REPL tab works" begin
    mt_with() do
        # The launcher is not found, so the launch fails at once.
        win = MT_GUI.WindowState("", nothing, 2;
            launch_options = (launcher = Cmd(["/nonexistent/mpiexec-for-tests"]), wrapper = MT_FAKE_WRAPPER,
                timeout = 5))
        stderr_path = tempname()
        try
            MT_GUI.new_tab!(win)
            tab = MT_GUI.open_mpi_tab!(win)
            mpi = tab.state
            open(stderr_path, "w") do io
                redirect_stderr(io) do
                    mt_run_until(() -> mpi.status !== :starting, win)
                end
            end
            @test mpi.status === :failed
            @test occursin("Could not start 2 MPI ranks", mpi.failure)
            @test occursin("was not found or is not executable", mpi.failure)
            @test win.mpi_props["status"] == "failed"
            @test win.mpi_props["message"] == mpi.failure
            @test isempty(mpi.views)
            @test occursin(mpi.failure, read(stderr_path, String))
            @test win.failure === nothing

            # The REPL tab still works: a session starts in its pane, and runs what is typed.
            repl = win.tabs.tabs[1].state
            MT_GUI.pane_sized!(repl, 400, 800, 8, 16)
            @test MT_ReplSession.is_started(repl.session.repl)
            @test MT_GUI.send_bytes!(repl, Vector{UInt8}(codeunits("println(2*21)\r"))) === true
            mt_run_until(() -> any(occursin("42", l) for l in MT_VT.screen_lines(repl.session.repl.term)), win)
        finally
            rm(stderr_path; force = true)
            MT_GUI.shutdown!(win)
        end
    end
end

@testset "MPI tab: a launch that does not connect in time fails the tab" begin
    mt_with(mode = "silent") do
        win = MT_GUI.WindowState("", nothing, 2; launch_options = merge(MT_OPTIONS, (timeout = 2,)))
        try
            tab = MT_GUI.open_mpi_tab!(win)
            mpi = tab.state
            mt_run_until(() -> mpi.status !== :starting, win)
            @test mpi.status === :failed
            @test occursin("only 0 of 2 ranks connected within 2 s", mpi.failure)
            @test win.mpi_props["status"] == "failed"
        finally
            MT_GUI.shutdown!(win)
        end
    end
    @test mt_fake_processes_gone()
end

@testset "MPI tab: closing the tab during the launch interrupts it and leaves no processes" begin
    mt_with(mode = "silent") do
        win = MT_GUI.WindowState("", nothing, 2; launch_options = MT_OPTIONS)
        try
            tab = MT_GUI.open_mpi_tab!(win)
            mpi = tab.state
            MT_GUI.close_tab!(win, tab.id)
            @test istaskdone(mpi.task)
            @test mpi.job === nothing
            @test isempty(win.tabs.tabs)
            @test mt_fake_processes_gone()
        finally
            MT_GUI.shutdown!(win)
        end
    end
end

@testset "MPI tab: closing the window shuts the job down, and each rank's exit is not repeated" begin
    mt_with() do
        win = MT_GUI.WindowState("", nothing, 3; launch_options = MT_OPTIONS)
        MT_GUI.new_tab!(win)
        MT_GUI.open_mpi_tab!(win)
        mpi = mt_mpi(win)
        try
            mt_run_until(() -> mpi.status !== :starting, win)
            pids = [v.session.repl.source.connection.pid for v in mpi.views]
            job_process = mpi.job.process
            MT_GUI.shutdown!(win)
            @test process_exited(job_process)
            @test mt_fake_processes_gone()
            @test timedwait(() -> all(!mt_exists(p) for p in pids), 10; pollint = 0.05) === :ok
        finally
            MT_GUI.shutdown!(win)
        end
    end
end

@testset "MPI tab: the window's count is used once, and the MPI tab opens once" begin
    win = MT_GUI.WindowState("", nothing, nothing)
    @test_throws "has no rank count" MT_GUI.open_mpi_tab!(win)
    MT_GUI.set_rank_count!(win, 2)
    @test isempty(win.tabs.tabs)
    mt_with() do
        try
            MT_GUI.open_mpi_tab!(win)
            mpi = mt_mpi(win)
            mt_run_until(() -> mpi.status !== :starting, win)
            @test_throws "already has an MPI tab" MT_GUI.open_mpi_tab!(win)
            MT_GUI.close_tab!(win, win.tabs.tabs[1].id)
            @test_throws "already has an MPI tab" MT_GUI.open_mpi_tab!(win)
        finally
            MT_GUI.shutdown!(win)
        end
    end
    @test mt_fake_processes_gone()
end

@testset "MPI tab: each rank pane is labelled with the rank of its connection" begin
    for n in (1, 2, 3, 4)
        mt_with() do
            win = MT_GUI.WindowState("", nothing, n; launch_options = MT_OPTIONS)
            try
                MT_GUI.new_tab!(win)
                MT_GUI.open_mpi_tab!(win)
                mpi = mt_mpi(win)
                mt_run_until(() -> mpi.status !== :starting, win)
                panes = mt_rank_panes(win)
                @test [v.session.repl.source.connection.rank for v in panes] == collect(0:n - 1)
                @test [v.props["rankLabel"] for v in panes] ==
                    [string(v.session.repl.source.connection.rank) for v in panes]
                @test [v.props["rankLabel"] for v in panes] == [string(r) for r in 0:n - 1]
                # The REPL pane has no label.
                repl = win.tabs.tabs[1].state
                @test win.views[repl.id].props["rankLabel"] == ""
            finally
                MT_GUI.shutdown!(win)
            end
        end
    end
end

@testset "MPI tab: a job whose connections are out of rank order is refused" begin
    mt_with() do
        job = MPIEnsemble.MpiLauncher.launch(2, 24, 80; MT_OPTIONS...)
        try
            win = MT_GUI.WindowState("", nothing, 2; launch_options = MT_OPTIONS)
            try
                mpi = MT_GUI.MpiTab(2)
                reversed = MPIEnsemble.MpiLauncher.Job(reverse(job.ranks), job.process, job.directory)
                @test_throws "connection 1 of the job is for rank 1, not rank 0" MT_GUI.attach_job!(win, mpi, reversed)
                @test isempty(mpi.views)
                @test isempty(mt_rank_panes(win))
            finally
                MT_GUI.shutdown!(win)
            end
        finally
            MPIEnsemble.MpiLauncher.shutdown!(job)
        end
    end
    @test mt_fake_processes_gone()
end

@testset "MPI tab: a Julia REPL in each rank prints the rank of its launcher, which is its label" begin
    # The ranks run the real wrapper, so each rank runs a Julia REPL, which can read the launcher's rank.
    mt_with() do
        win = MT_GUI.WindowState("", nothing, 3; launch_options = (launcher = MT_FAKE_LAUNCHER, timeout = MT_TIMEOUT))
        try
            MT_GUI.open_mpi_tab!(win)
            mpi = mt_mpi(win)
            mt_run_until(() -> mpi.status !== :starting, win)
            mt_size!(win)
            panes = mt_rank_panes(win)
            for view in panes
                @test MT_GUI.send_bytes!(view, Vector{UInt8}(codeunits("println(ENV[\"OMPI_COMM_WORLD_RANK\"])\r"))) === true
            end
            # A line of digits alone is the output of println; the echoed command line is not.
            printed(view) = [strip(l) for l in split(mt_text(view), "\n") if occursin(r"^\s*\d+\s*$", l)]
            mt_run_until(() -> all(!isempty(printed(v)) for v in panes), win; timeout = 120)
            for view in panes
                @test printed(view) == [string(view.session.repl.source.connection.rank)]
                @test printed(view) == [view.props["rankLabel"]]
            end
        finally
            MT_GUI.shutdown!(win)
        end
    end
    @test mt_fake_processes_gone()
end

# The processes whose parent is `pid`, read from /proc.
function mt_children(pid::Integer)
    found = Int[]
    for entry in readdir("/proc")
        all(isdigit, entry) || continue
        stat = try
            read("/proc/$entry/stat", String)
        catch
            continue
        end
        # The command name is in parentheses and may contain spaces. The state comes first, then the parent.
        fields = split(stat[(findlast(')', stat) + 1):end])
        parse(Int, fields[2]) == pid && push!(found, parse(Int, entry))
    end
    return found
end

@testset "MPI tab: killing the job ends every rank, and each pane keeps its output" begin
    mt_with() do
        win = MT_GUI.WindowState("", nothing, 3; launch_options = MT_OPTIONS)
        try
            tab = MT_GUI.open_mpi_tab!(win)
            mpi = tab.state
            mt_run_until(() -> mpi.status !== :starting, win)
            mt_size!(win)
            mt_run_until(() -> all(occursin("resize 25 100", mt_text(v)) for v in mpi.views), win)
            @test MT_GUI.send_bytes!(mpi.views[2], Vector{UInt8}(codeunits("before-kill"))) === true
            mt_run_until(() -> occursin("before-kill", mt_text(mpi.views[2])), win)
            @test MT_GUI.mpi_killable(mpi)
            @test win.mpi_props["killable"] == true

            pids = [v.session.repl.source.connection.pid for v in mpi.views]
            job_process = mpi.job.process
            ids = [v.id for v in mpi.views]
            @test MT_GUI.kill_mpi!(win, tab.id) === nothing

            @test mpi.status === :killed
            @test mpi.failure === nothing
            @test win.mpi_props["status"] == "killed"
            @test win.mpi_props["killable"] == false
            @test !MT_GUI.mpi_killable(mpi)
            @test process_exited(job_process)
            @test timedwait(() -> all(!mt_exists(p) for p in pids), 10; pollint = 0.05) === :ok
            @test mt_fake_processes_gone()

            # Every rank reports that it ended. No exit status came from the ranks, so none is recorded.
            for view in mpi.views
                @test view.killed
                @test view.session.repl.exit === nothing
                @test !MT_ReplSession.has_ended(view.session.repl)
                @test view.props["ended"] == true
                @test view.props["exitText"] ==
                    "Rank $(view.rank) ended: the MPI job was killed. Restarting needs the whole MPI job to restart."
                @test view.failure === nothing
            end

            # The panes stay in the tab, with their output, which is still fed after the kill.
            @test [v.id for v in mt_rank_panes(win)] == ids
            @test all(haskey(win.views, id) for id in ids)
            for _ in 1:20
                MT_GUI.service!(win)
                sleep(0.005)
            end
            @test win.failure === nothing
            @test occursin("before-kill", mt_text(mpi.views[2]))
            @test occursin("resize 25 100", mt_text(mpi.views[1]))
            @test !occursin("before-kill", mt_text(mpi.views[1]))

            # Input is refused by every pane, and nothing is raised.
            @test MT_GUI.send_bytes!(mpi.views[1], Vector{UInt8}(codeunits("after-kill"))) === false
            @test MT_GUI.key_input!(win, mpi.views[1], 0, "after-kill", 0) === false
            @test MT_GUI.paste_input!(win, mpi.views[3], "after-kill") === false
            @test win.failure === nothing

            # Killing again does nothing, and the state is unchanged.
            @test MT_GUI.kill_mpi!(win, tab.id) === nothing
            @test mpi.status === :killed
            @test all(v.killed for v in mpi.views)

            # Closing the killed tab removes its panes; the job has nothing left to stop.
            MT_GUI.close_tab!(win, tab.id)
            @test isempty(win.tabs.tabs)
            @test isempty(mt_rank_panes(win))
            @test process_exited(job_process)
            @test mt_fake_processes_gone()
        finally
            MT_GUI.shutdown!(win)
        end
    end
end

@testset "MPI tab: killing the job stops the Julia of each rank" begin
    # The ranks run the real wrapper, which runs julia in a pseudo-terminal of its own. Each rank's julia must
    # stop when its job is killed, not only the launcher and the wrappers.
    mt_with() do
        win = MT_GUI.WindowState("", nothing, 2; launch_options = (launcher = MT_FAKE_LAUNCHER, timeout = MT_TIMEOUT))
        try
            tab = MT_GUI.open_mpi_tab!(win)
            mpi = tab.state
            mt_run_until(() -> mpi.status !== :starting, win)
            mt_size!(win)
            panes = mt_rank_panes(win)
            for view in panes
                @test MT_GUI.send_bytes!(view, Vector{UInt8}(codeunits("println(\"up-\", ENV[\"OMPI_COMM_WORLD_RANK\"])\r"))) === true
            end
            mt_run_until(() -> all(occursin("up-$(v.rank)", mt_text(v)) for v in panes), win; timeout = 120)

            wrappers = [v.session.repl.source.connection.pid for v in panes]
            julias = reduce(vcat, mt_children.(wrappers); init = Int[])
            @test length(julias) == length(wrappers)
            @test MT_GUI.kill_mpi!(win, tab.id) === nothing
            @test timedwait(() -> all(!mt_exists(p) for p in vcat(wrappers, julias)), 30; pollint = 0.05) === :ok
            @test mt_fake_processes_gone()
            @test win.failure === nothing
        finally
            MT_GUI.shutdown!(win)
        end
    end
end

@testset "MPI tab: a job can be killed only once it has started, and a REPL tab is not an MPI job" begin
    mt_with(mode = "silent") do
        win = MT_GUI.WindowState("", nothing, 2; launch_options = MT_OPTIONS)
        try
            MT_GUI.new_tab!(win)
            repl_id = win.tabs.tabs[1].id
            @test_throws "is not an MPI tab" MT_GUI.kill_mpi!(win, repl_id)
            tab = MT_GUI.open_mpi_tab!(win)
            mpi = tab.state
            # The job is still starting, so there is nothing to kill yet.
            @test mpi.status === :starting
            @test !MT_GUI.mpi_killable(mpi)
            @test win.mpi_props["killable"] == false
            @test_throws "cannot be killed while it is starting" MT_GUI.kill_mpi!(win, tab.id)
            @test mpi.status === :starting
            @test win.failure === nothing
            MT_GUI.close_tab!(win, tab.id)
            @test mt_fake_processes_gone()
            # A kill for a tab that has been closed does nothing, and raises nothing.
            @test MT_GUI.tab_call(id -> MT_GUI.kill_mpi!(win, id), win, tab.id, :closed) === :closed
            @test win.failure === nothing
        finally
            MT_GUI.shutdown!(win)
        end
    end
    mt_with(mode = "no_exit@0") do
        # Rank 0's connection closes without an EXIT frame. Its job may still be running, so it stays killable.
        win = MT_GUI.WindowState("", nothing, 2; launch_options = MT_OPTIONS)
        try
            tab = MT_GUI.open_mpi_tab!(win)
            mpi = tab.state
            mt_run_until(() -> mpi.status !== :starting, win)
            mt_size!(win)
            mt_run_until(() -> mpi.views[1].failure !== nothing, win)
            @test MT_GUI.mpi_killable(mpi)
            MT_GUI.close_tab!(win, tab.id)
        finally
            MT_GUI.shutdown!(win)
        end
    end
    mt_with(mode = "silent") do
        # The launch fails: the job cannot be killed, and the tab says so.
        win = MT_GUI.WindowState("", nothing, 2;
            launch_options = (launcher = Cmd(["/nonexistent/mpiexec-for-tests"]), wrapper = MT_FAKE_WRAPPER, timeout = 5))
        try
            tab = MT_GUI.open_mpi_tab!(win)
            mpi = tab.state
            redirect_stderr(devnull) do
                mt_run_until(() -> mpi.status !== :starting, win)
            end
            @test mpi.status === :failed
            @test !MT_GUI.mpi_killable(mpi)
            @test_throws "cannot be killed while it is failed" MT_GUI.kill_mpi!(win, tab.id)
            @test win.failure === nothing
        finally
            MT_GUI.shutdown!(win)
        end
    end
end

@testset "MPI tab: a rank that ended before the kill keeps its own exit status" begin
    # Rank 0 ends on its own at once, and rank 1 keeps running, so the job can still be killed.
    mt_with(mode = "exit_frame@0") do
        win = MT_GUI.WindowState("", nothing, 2; launch_options = MT_OPTIONS)
        try
            tab = MT_GUI.open_mpi_tab!(win)
            mpi = tab.state
            mt_run_until(() -> mpi.status !== :starting, win)
            mt_size!(win)
            ended = only(v for v in mpi.views if v.rank == 0)
            running = only(v for v in mpi.views if v.rank == 1)
            mt_run_until(() -> MT_ReplSession.has_ended(ended.session.repl), win)
            @test MT_GUI.mpi_killable(mpi)
            text = ended.props["exitText"]
            @test MT_GUI.kill_mpi!(win, tab.id) === nothing
            @test mpi.status === :killed
            @test !ended.killed
            @test running.killed
            @test ended.props["exitText"] == text
            @test ended.session.repl.exit == MT_ReplSession.ExitInfo(7, 0)
            @test win.failure === nothing
        finally
            MT_GUI.shutdown!(win)
        end
    end
end

@testset "MPI tab: a rank whose connection failed before the kill keeps the failure in its pane" begin
    mt_with(mode = "no_exit@1") do
        win = MT_GUI.WindowState("", nothing, 2; launch_options = MT_OPTIONS)
        try
            tab = MT_GUI.open_mpi_tab!(win)
            mpi = tab.state
            mt_run_until(() -> mpi.status !== :starting, win)
            mt_size!(win)
            failing = only(v for v in mpi.views if v.rank == 1)
            other = only(v for v in mpi.views if v.rank == 0)
            mt_run_until(() -> failing.failure !== nothing, win)
            @test MT_GUI.kill_mpi!(win, tab.id) === nothing
            @test failing.killed
            @test failing.props["exitText"] == "Rank 1 failed: " * sprint(showerror, failing.failure)
            @test other.props["exitText"] ==
                "Rank 0 ended: the MPI job was killed. Restarting needs the whole MPI job to restart."
            @test win.failure === nothing
        finally
            MT_GUI.shutdown!(win)
        end
    end
end

# The restart entries of a pane's log: the text that describes how each earlier session ended.
mt_restart_texts(view) =
    [e.text for e in MT_LL.window(view.session.log, 1:length(view.session.log)) if e.kind === :restart]

# The processes of the fake job of `view`'s rank: its wrapper, which is alive while the connection is open.
mt_wrapper_pids(views) = [v.session.repl.source.connection.pid for v in views]

@testset "MPI tab: restart after a kill keeps each pane's output, and the new job's output follows it" begin
    mt_with() do
        win = MT_GUI.WindowState("", nothing, 3; launch_options = MT_OPTIONS)
        try
            tab = MT_GUI.open_mpi_tab!(win)
            mpi = tab.state
            mt_run_until(() -> mpi.status !== :starting, win)
            mt_size!(win)
            mt_run_until(() -> all(occursin("resize 25 100", mt_text(v)) for v in mpi.views), win)
            @test MT_GUI.send_bytes!(mpi.views[2], Vector{UInt8}(codeunits("before-kill"))) === true
            mt_run_until(() -> occursin("before-kill", mt_text(mpi.views[2])), win)

            ids = [v.id for v in mpi.views]
            old_job = mpi.job
            old_directory = old_job.directory
            old_pids = mt_wrapper_pids(mpi.views)
            @test MT_GUI.kill_mpi!(win, tab.id) === nothing
            @test mpi.status === :killed
            @test win.mpi_props["killable"] == false

            @test MT_GUI.restart_mpi!(win, tab.id) === nothing
            @test mpi.status === :starting
            @test win.mpi_props["status"] == "starting"
            @test win.mpi_props["message"] == "Restarting 3 MPI ranks…"
            mt_run_until(() -> mpi.status !== :starting, win)
            @test mpi.status === :running
            @test mpi.failure === nothing
            @test win.mpi_props["status"] == "running"
            @test win.mpi_props["killable"] == true
            @test win.failure === nothing

            # The same panes, in the same order, with the ranks of the new job.
            @test [v.id for v in mpi.views] == ids
            @test [v.id for v in mt_rank_panes(win)] == ids
            @test [v.rank for v in mpi.views] == [0, 1, 2]
            @test [v.session.repl.source.connection.rank for v in mpi.views] == [0, 1, 2]
            @test mpi.job !== old_job
            new_pids = mt_wrapper_pids(mpi.views)
            @test isempty(intersect(old_pids, new_pids))
            @test all(!v.killed && v.failure === nothing for v in mpi.views)
            @test all(v.props["ended"] == false && v.props["exitText"] == "" for v in mpi.views)
            @test all(v.session.visible for v in mpi.views)
            @test mpi.targets == Set(0:2)

            # The old job has been shut down: its launcher and wrappers have exited, and its socket directory is gone.
            @test process_exited(old_job.process)
            @test !isdir(old_directory)
            @test timedwait(() -> all(!mt_exists(p) for p in old_pids), 10; pollint = 0.05) === :ok

            # Each pane logs the end of its old session, and the old output is still there.
            for view in mpi.views
                @test mt_restart_texts(view) == [MT_ReplSession.UNEXITED_DESCRIPTION]
            end
            @test occursin("before-kill", mt_text(mpi.views[2]))

            # The new session writes after the old output, and the pane shows the new output.
            for view in mpi.views
                @test MT_GUI.send_bytes!(view, Vector{UInt8}(codeunits("after-restart"))) === true
            end
            mt_run_until(() -> mt_all_show(mpi.views, "after-restart"), win)
            for view in mpi.views
                text = mt_text(view)
                restart_at = findfirst(MT_ReplSession.UNEXITED_DESCRIPTION, text)
                @test restart_at !== nothing
                @test findfirst("resize 25 100", text).start < restart_at.start
                @test findnext("resize 25 100", text, restart_at.stop + 1) !== nothing
                @test restart_at.stop < findfirst("after-restart", text).start
            end
            @test occursin("before-kill", mt_text(mpi.views[2]))
            @test !occursin("before-kill", mt_text(mpi.views[1]))
            @test win.failure === nothing

            new_directory = mpi.job.directory
            @test MT_GUI.close_tab!(win, tab.id) === nothing
            @test isempty(win.tabs.tabs)
            @test isempty(mt_rank_panes(win))
            @test !isdir(new_directory)
            @test mt_fake_processes_gone()
        finally
            MT_GUI.shutdown!(win)
        end
    end
end

@testset "MPI tab: restart after every rank ended on its own" begin
    # Each rank exits when it reads "exit", as Julia does when it is asked to exit. No rank is killed.
    mt_with(mode = "exit_on_input") do
        win = MT_GUI.WindowState("", nothing, 2; launch_options = MT_OPTIONS)
        try
            tab = MT_GUI.open_mpi_tab!(win)
            mpi = tab.state
            mt_run_until(() -> mpi.status !== :starting, win)
            mt_size!(win)
            mt_run_until(() -> all(occursin("resize 25 100", mt_text(v)) for v in mpi.views), win)
            @test MT_GUI.send_bytes!(mpi.views[1], Vector{UInt8}(codeunits("before-stop"))) === true
            mt_run_until(() -> occursin("before-stop", mt_text(mpi.views[1])), win)

            old_directory = mpi.job.directory
            old_pids = mt_wrapper_pids(mpi.views)
            for view in mpi.views
                @test MT_GUI.send_bytes!(view, Vector{UInt8}(codeunits("exit"))) === true
            end
            mt_run_until(() -> mpi.status === :ended, win)
            @test all(MT_ReplSession.has_ended(v.session.repl) for v in mpi.views)
            @test all(v.session.repl.exit == MT_ReplSession.ExitInfo(0, 0) for v in mpi.views)
            @test win.mpi_props["status"] == "ended"
            @test win.mpi_props["message"] == "The MPI job has ended."
            @test win.mpi_props["messageFailed"] == false
            @test win.mpi_props["killable"] == false
            @test !MT_GUI.mpi_killable(mpi)
            @test_throws "cannot be killed while it is ended" MT_GUI.kill_mpi!(win, tab.id)
            @test all(v.props["ended"] == true for v in mpi.views)
            @test all(v.props["exitText"] == "Rank $(v.rank) ended: Julia exited with code 0. " *
                "Restarting needs the whole MPI job to restart." for v in mpi.views)
            # Input is refused by the ended ranks.
            @test MT_GUI.send_bytes!(mpi.views[2], Vector{UInt8}(codeunits("after-end"))) === false

            @test MT_GUI.restart_mpi!(win, tab.id) === nothing
            mt_run_until(() -> mpi.status === :running, win)
            @test win.failure === nothing
            @test !isdir(old_directory)
            @test timedwait(() -> all(!mt_exists(p) for p in old_pids), 10; pollint = 0.05) === :ok
            @test all(!MT_ReplSession.has_ended(v.session.repl) for v in mpi.views)
            @test all(v.props["ended"] == false for v in mpi.views)
            for view in mpi.views
                @test mt_restart_texts(view) == ["Julia exited with code 0"]
            end
            @test occursin("before-stop", mt_text(mpi.views[1]))

            # The new job takes input, and the ranks end again when asked, so it can be restarted again.
            for view in mpi.views
                @test MT_GUI.send_bytes!(view, Vector{UInt8}(codeunits("second-job"))) === true
            end
            mt_run_until(() -> mt_all_show(mpi.views, "second-job"), win)
            for view in mpi.views
                @test MT_GUI.send_bytes!(view, Vector{UInt8}(codeunits("exit"))) === true
            end
            mt_run_until(() -> mpi.status === :ended, win)
            @test MT_GUI.restart_mpi!(win, tab.id) === nothing
            mt_run_until(() -> mpi.status === :running, win)
            @test all(length(mt_restart_texts(v)) == 2 for v in mpi.views)
            @test win.failure === nothing
        finally
            MT_GUI.shutdown!(win)
        end
    end
    @test mt_fake_processes_gone()
end

@testset "MPI tab: restart is refused while the job runs or starts, and for a REPL tab" begin
    mt_with() do
        win = MT_GUI.WindowState("", nothing, 2; launch_options = MT_OPTIONS)
        try
            MT_GUI.new_tab!(win)
            repl_id = win.tabs.tabs[1].id
            @test_throws "is not an MPI tab" MT_GUI.restart_mpi!(win, repl_id)
            tab = MT_GUI.open_mpi_tab!(win)
            mpi = tab.state
            @test_throws "cannot be restarted while it is starting" MT_GUI.restart_mpi!(win, tab.id)
            mt_run_until(() -> mpi.status !== :starting, win)
            mt_size!(win)
            @test_throws "cannot be restarted while it is running" MT_GUI.restart_mpi!(win, tab.id)
            @test mpi.status === :running
            @test all(!MT_ReplSession.has_ended(v.session.repl) for v in mpi.views)
            @test win.failure === nothing
        finally
            MT_GUI.shutdown!(win)
        end
    end
    @test mt_fake_processes_gone()
    mt_with(mode = "silent") do
        win = MT_GUI.WindowState("", nothing, 2; launch_options = MT_OPTIONS)
        try
            tab = MT_GUI.open_mpi_tab!(win)
            @test_throws "cannot be restarted while it is starting" MT_GUI.restart_mpi!(win, tab.id)
            MT_GUI.close_tab!(win, tab.id)
        finally
            MT_GUI.shutdown!(win)
        end
    end
    @test mt_fake_processes_gone()
end

@testset "MPI tab: kill, restart and kill again, each time leaving no processes or directories" begin
    mt_with() do
        win = MT_GUI.WindowState("", nothing, 2; launch_options = MT_OPTIONS)
        try
            tab = MT_GUI.open_mpi_tab!(win)
            mpi = tab.state
            mt_run_until(() -> mpi.status !== :starting, win)
            mt_size!(win)
            directories = String[]
            for round in 1:3
                push!(directories, mpi.job.directory)
                pids = mt_wrapper_pids(mpi.views)
                @test MT_GUI.kill_mpi!(win, tab.id) === nothing
                @test mpi.status === :killed
                @test timedwait(() -> all(!mt_exists(p) for p in pids), 10; pollint = 0.05) === :ok
                @test !isdir(directories[end])
                @test MT_GUI.restart_mpi!(win, tab.id) === nothing
                mt_run_until(() -> mpi.status === :running, win)
                @test MT_GUI.send_bytes!(mpi.views[1], Vector{UInt8}(codeunits("round-$round"))) === true
                mt_run_until(() -> occursin("round-$round", mt_text(mpi.views[1])), win)
            end
            @test all(length(mt_restart_texts(v)) == 3 for v in mpi.views)
            @test all(occursin("round-$r", mt_text(mpi.views[1])) for r in 1:3)
            @test win.failure === nothing
            MT_GUI.close_tab!(win, tab.id)
            @test mt_fake_processes_gone()
            @test all(!isdir(d) for d in directories)
        finally
            MT_GUI.shutdown!(win)
        end
    end
end

@testset "MPI tab: a restarted job's panes take input, and zoom and targets still route it" begin
    mt_with() do
        win = MT_GUI.WindowState("", nothing, 3; launch_options = MT_OPTIONS)
        try
            tab = MT_GUI.open_mpi_tab!(win)
            mpi = tab.state
            mt_run_until(() -> mpi.status !== :starting, win)
            mt_size!(win)
            mt_run_until(() -> all(occursin("resize 25 100", mt_text(v)) for v in mpi.views), win)
            @test MT_GUI.kill_mpi!(win, tab.id) === nothing
            @test MT_GUI.restart_mpi!(win, tab.id) === nothing
            mt_run_until(() -> mpi.status === :running, win)
            mt_size!(win)
            mt_run_until(() -> all(occursin("resize 25 100", mt_text(v)) for v in mpi.views), win)

            # Every rank receives input from the focused pane, as before the restart.
            @test MT_GUI.key_input!(win, mpi.views[1], 0, "all-after", 0) === true
            mt_run_until(() -> mt_all_show(mpi.views, "all-after"), win)

            # A zoomed rank alone receives input. The pane of rank 2 is the focused one here, since a pane that
            # does not receive input reports that its key was not sent.
            mpi.zoomed = 2
            @test [v.rank for v in MT_GUI.route_targets(mpi)] == [2]
            @test MT_GUI.key_input!(win, mpi.views[3], 0, "zoom-two", 0) === true
            mt_run_until(() -> occursin("zoom-two", mt_text(mpi.views[3])), win)
            @test !occursin("zoom-two", mt_text(mpi.views[1]))
            @test !occursin("zoom-two", mt_text(mpi.views[2]))
            mpi.zoomed = nothing

            # Only the ranks in targets receive input.
            mpi.targets = Set([0, 2])
            @test [v.rank for v in MT_GUI.route_targets(mpi)] == [0, 2]
            @test MT_GUI.key_input!(win, mpi.views[3], 0, "two-only", 0) === true
            mt_run_until(() -> occursin("two-only", mt_text(mpi.views[3])), win)
            @test !occursin("two-only", mt_text(mpi.views[2]))
            @test win.failure === nothing
        finally
            MT_GUI.shutdown!(win)
        end
    end
    @test mt_fake_processes_gone()
end

@testset "MPI tab: a failed restart keeps the panes, and a second restart succeeds" begin
    mt_with() do
        win = MT_GUI.WindowState("", nothing, 2; launch_options = MT_OPTIONS)
        try
            tab = MT_GUI.open_mpi_tab!(win)
            mpi = tab.state
            mt_run_until(() -> mpi.status !== :starting, win)
            mt_size!(win)
            mt_run_until(() -> all(occursin("resize 25 100", mt_text(v)) for v in mpi.views), win)
            @test MT_GUI.send_bytes!(mpi.views[1], Vector{UInt8}(codeunits("before-failure"))) === true
            mt_run_until(() -> occursin("before-failure", mt_text(mpi.views[1])), win)
            ids = [v.id for v in mpi.views]
            @test MT_GUI.kill_mpi!(win, tab.id) === nothing

            # The next job's wrappers report a job of another size, so its launch fails.
            withenv("FAKE_WRAPPER_MODE" => "wrong_size") do
                redirect_stderr(devnull) do
                    MT_GUI.restart_mpi!(win, tab.id)
                    mt_run_until(() -> mpi.status !== :starting, win)
                end
            end
            @test mpi.status === :ended
            @test mpi.job === nothing
            @test mpi.failure === nothing
            @test occursin("Could not restart 2 MPI ranks", win.mpi_props["message"])
            @test win.mpi_props["messageFailed"] == true
            @test win.mpi_props["panes"] == true
            @test win.mpi_props["killable"] == false
            @test [v.id for v in mt_rank_panes(win)] == ids
            @test occursin("before-failure", mt_text(mpi.views[1]))
            @test win.failure === nothing

            # Restart again with the normal wrappers, which succeeds.
            @test MT_GUI.restart_mpi!(win, tab.id) === nothing
            mt_run_until(() -> mpi.status === :running, win)
            @test win.mpi_props["messageFailed"] == false
            @test all(mt_restart_texts(v) == [MT_ReplSession.UNEXITED_DESCRIPTION] for v in mpi.views)
            @test MT_GUI.send_bytes!(mpi.views[2], Vector{UInt8}(codeunits("works"))) === true
            mt_run_until(() -> occursin("works", mt_text(mpi.views[2])), win)
            @test win.failure === nothing
        finally
            MT_GUI.shutdown!(win)
        end
    end
    @test mt_fake_processes_gone()
end

@testset "MPI tab: a rank whose connection failed gets a new connection after a restart" begin
    mt_with(mode = "no_exit@0") do
        win = MT_GUI.WindowState("", nothing, 2; launch_options = MT_OPTIONS)
        try
            tab = MT_GUI.open_mpi_tab!(win)
            mpi = tab.state
            mt_run_until(() -> mpi.status !== :starting, win)
            mt_size!(win)
            failed = only(v for v in mpi.views if v.rank == 0)
            mt_run_until(() -> failed.failure !== nothing, win)
            @test MT_GUI.kill_mpi!(win, tab.id) === nothing
            @test failed.killed
            withenv("FAKE_WRAPPER_MODE" => "echo") do
                @test MT_GUI.restart_mpi!(win, tab.id) === nothing
                mt_run_until(() -> mpi.status === :running, win)
            end
            @test failed.failure === nothing
            @test !failed.killed
            @test MT_GUI.send_bytes!(failed, Vector{UInt8}(codeunits("rank-zero"))) === true
            mt_run_until(() -> occursin("rank-zero", mt_text(failed)), win)
            @test win.failure === nothing
        finally
            MT_GUI.shutdown!(win)
        end
    end
    @test mt_fake_processes_gone()
end
