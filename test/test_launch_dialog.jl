# The launch dialog's results, as the window handles them (Gui.jl): a serial REPL tab, an MPI tab with a rank
# count, or a cancel. The dialog itself is QML and is not run here. The MPI tab is started by the fake launcher
# (test/mpi/fake_mpiexec.sh) with the fake wrapper, so no julia runs in a rank.

# Loading QML creates a QGuiApplication, which needs a Qt platform plugin; the offscreen one needs no display.
withenv("QT_QPA_PLATFORM" => "offscreen") do
    MPIEnsemble.gui_function(:run_single_repl)
end
const LD_GUI = Base.invokelatest(getfield, MPIEnsemble, :Gui)

const LD_FAKE_LAUNCHER = Cmd(["sh", joinpath(@__DIR__, "mpi", "fake_mpiexec.sh")])
const LD_FAKE_WRAPPER = joinpath(@__DIR__, "mpi", "fake_wrapper.py")
const LD_OPTIONS = (launcher = LD_FAKE_LAUNCHER, wrapper = LD_FAKE_WRAPPER, timeout = 60)

# Drive the window's event loop until `done()` holds, as `Gui.run_loop!` does without QML.
function ld_run_until(done, win; timeout::Real = 60)
    deadline = time() + timeout
    while !done()
        time() < deadline || error("timed out after $timeout s")
        LD_GUI.check_failure!(win)
        LD_GUI.service!(win)
        sleep(0.005)
    end
    return nothing
end

ld_kinds(win) = [t.kind for t in win.tabs.tabs]
ld_titles(win) = [LD_GUI.TabSet.tab_title(t) for t in win.tabs.tabs]

# Run `f` with XDG_RUNTIME_DIR set, which the launcher needs.
ld_with(f) = withenv(f, "XDG_RUNTIME_DIR" => get(ENV, "XDG_RUNTIME_DIR", tempdir()), "FAKE_WRAPPER_MODE" => "echo")

@testset "launch dialog: without an argument the window has no tab until the dialog is answered" begin
    win = LD_GUI.WindowState("", nothing, nothing; launch_options = LD_OPTIONS)
    @test isempty(win.tabs.tabs)
    @test LD_GUI.TabSet.selected_id(win.tabs) == 0
    @test LD_GUI.TabSet.window_should_close(win.tabs) == true
    @test win.props["askLaunch"] == true
    @test win.props["lastRanks"] == 0
    @test win.props["selected"] == 0
end

@testset "launch dialog: with a rank count the only tab at start-up is the MPI tab" begin
    win = LD_GUI.WindowState("", nothing, 2; launch_options = LD_OPTIONS)
    @test win.props["askLaunch"] == false
    @test win.props["lastRanks"] == 2
    ld_with() do
        try
            LD_GUI.open_mpi_tab!(win)
            @test ld_kinds(win) == [:mpi]
            @test ld_titles(win) == ["MPI"]
            ld_run_until(() -> only(t.state for t in win.tabs.tabs).status !== :starting, win)
        finally
            LD_GUI.shutdown!(win)
        end
    end
end

@testset "launch dialog: Serial Julia REPL adds a serial tab, and cancel adds nothing" begin
    win = LD_GUI.WindowState("", nothing, nothing; launch_options = LD_OPTIONS)
    try
        LD_GUI.launch_serial!(win)
        @test ld_kinds(win) == [:repl]
        @test ld_titles(win) == ["Julia 1"]
        @test win.props["askLaunch"] == false
        @test win.props["selectedPane"] == win.tabs.tabs[1].state.id
        @test win.props["closeRequest"] == 0

        # Cancel of a later dialog, as from the + button, changes nothing.
        LD_GUI.cancel_launch!(win)
        @test ld_kinds(win) == [:repl]
        @test win.props["closeRequest"] == 0

        # A second serial result, as from the + button, adds a tab and selects it.
        LD_GUI.launch_serial!(win)
        @test ld_titles(win) == ["Julia 1", "Julia 2"]
        @test LD_GUI.TabSet.selected_id(win.tabs) == win.tabs.tabs[2].id
    finally
        LD_GUI.shutdown!(win)
    end
end

@testset "launch dialog: cancelling the first dialog closes the window" begin
    win = LD_GUI.WindowState("", nothing, nothing; launch_options = LD_OPTIONS)
    LD_GUI.cancel_launch!(win)
    @test isempty(win.tabs.tabs)
    @test win.props["askLaunch"] == false
    @test win.props["closeRequest"] == 1
end

@testset "launch dialog: an invalid rank count is an error and adds nothing" begin
    win = LD_GUI.WindowState("", nothing, nothing; launch_options = LD_OPTIONS)
    @test_throws "rank count must be a positive integer" LD_GUI.launch_mpi!(win, 0)
    @test isempty(win.tabs.tabs)
    @test win.props["askLaunch"] == true
    @test win.props["lastRanks"] == 0
end

@testset "launch dialog: MPI tabs can be opened while others are open, each with its own count" begin
    win = LD_GUI.WindowState("", nothing, nothing; launch_options = LD_OPTIONS)
    ld_with() do
        try
            LD_GUI.launch_serial!(win)
            LD_GUI.launch_mpi!(win, 2)
            @test ld_kinds(win) == [:repl, :mpi]
            @test ld_titles(win) == ["Julia 1", "MPI"]
            @test LD_GUI.TabSet.selected_id(win.tabs) == win.tabs.tabs[2].id
            @test win.props["askLaunch"] == false
            @test win.props["lastRanks"] == 2
            first_mpi = win.tabs.tabs[2].state
            ld_run_until(() -> first_mpi.status !== :starting, win)

            # A second MPI result while the first MPI tab is open opens another tab, with its own count.
            LD_GUI.launch_mpi!(win, 3)
            @test ld_kinds(win) == [:repl, :mpi, :mpi]
            @test ld_titles(win) == ["Julia 1", "MPI", "MPI 2"]
            @test LD_GUI.TabSet.selected_id(win.tabs) == win.tabs.tabs[3].id
            @test win.props["lastRanks"] == 3
            second_mpi = win.tabs.tabs[3].state
            ld_run_until(() -> second_mpi.status !== :starting, win)
            @test (first_mpi.nranks, second_mpi.nranks) == (2, 3)
            @test length(first_mpi.views) == 2
            @test length(second_mpi.views) == 3
            @test first_mpi.job !== second_mpi.job

            # Closing the first MPI tab leaves the other tab and its job. Its number is not given to a new tab.
            LD_GUI.close_tab!(win, win.tabs.tabs[2].id)
            @test ld_kinds(win) == [:repl, :mpi]
            @test ld_titles(win) == ["Julia 1", "MPI 2"]
            @test second_mpi.status === :running
            @test second_mpi.job !== nothing
            @test first_mpi.job === nothing
            @test length(second_mpi.views) == 3
            @test win.props["lastRanks"] == 3
            LD_GUI.launch_mpi!(win, 1)
            @test ld_titles(win) == ["Julia 1", "MPI 2", "MPI 3"]
            @test win.props["lastRanks"] == 1
            ld_run_until(() -> win.tabs.tabs[3].state.status !== :starting, win)
        finally
            LD_GUI.shutdown!(win)
        end
    end
    @test LD_GUI.TabSet.window_should_close(win.tabs) == false
end

@testset "launch dialog: after a serial start-up, + opens a serial tab and an MPI tab" begin
    win = LD_GUI.WindowState("", nothing, 0; launch_options = LD_OPTIONS)
    ld_with() do
        try
            LD_GUI.open_startup_tab!(win)
            @test ld_kinds(win) == [:repl]
            LD_GUI.launch_serial!(win)
            @test ld_titles(win) == ["Julia 1", "Julia 2"]
            LD_GUI.launch_mpi!(win, 2)
            @test ld_kinds(win) == [:repl, :repl, :mpi]
            @test ld_titles(win) == ["Julia 1", "Julia 2", "MPI"]
            @test win.props["askLaunch"] == false
            @test win.props["lastRanks"] == 2
            mpi = win.tabs.tabs[3].state
            ld_run_until(() -> mpi.status !== :starting, win)
            @test mpi.nranks == 2
            @test length(mpi.views) == 2
        finally
            LD_GUI.shutdown!(win)
        end
    end
end
