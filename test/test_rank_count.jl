# The rank count from the command line or the launch dialog, as recorded in the window state. The state is
# built without opening a window. Loading the Gui module needs a Qt platform plugin, so the offscreen one
# is used, and no window is shown.
withenv("QT_QPA_PLATFORM" => "offscreen") do
    MPIEnsemble.gui_function(:run_single_repl)
end
const RC_GUI = Base.invokelatest(getfield, MPIEnsemble, :Gui)
@testset "rank count: an argument is recorded and no dialog is asked for" begin
    win = RC_GUI.WindowState("", nothing, 3)
    @test win.rank_count == 3
    @test win.props["lastRanks"] == 3
    @test win.props["askLaunch"] == false
end

@testset "rank count: without an argument the window asks for it" begin
    win = RC_GUI.WindowState("", nothing, nothing)
    @test win.rank_count === nothing
    @test win.props["askLaunch"] == true
end

@testset "rank count: an invalid dialog value is an error and records nothing" begin
    win = RC_GUI.WindowState("", nothing, nothing)
    @test_throws "rank count must be a positive integer" RC_GUI.launch_mpi!(win, 0)
    @test isempty(win.tabs.tabs)
    @test win.rank_count === nothing
    @test win.props["askLaunch"] == true
    @test win.props["lastRanks"] == 0
end

@testset "rank count: cancelling the first tab's dialog records nothing and closes the window" begin
    win = RC_GUI.WindowState("", nothing, nothing)
    RC_GUI.cancel_launch!(win)
    @test win.rank_count === nothing
    @test win.props["askLaunch"] == false
    @test win.props["closeRequest"] == 1
end

@testset "rank count: 0 records a serial start-up, and no dialog is asked for" begin
    win = RC_GUI.WindowState("", nothing, 0)
    @test win.rank_count == 0
    @test win.props["lastRanks"] == 0
    @test win.props["askLaunch"] == false
end

@testset "rank count: 0 at start-up opens exactly one serial REPL tab, and no MPI tab or dialog" begin
    win = RC_GUI.WindowState("", nothing, 0)
    try
        RC_GUI.open_startup_tab!(win)
        @test [t.kind for t in win.tabs.tabs] == [:repl]
        @test [RC_GUI.TabSet.tab_title(t) for t in win.tabs.tabs] == ["Julia 1"]
        @test win.props["askLaunch"] == false
        @test win.props["closeRequest"] == 0
        @test win.props["selectedPane"] == win.tabs.tabs[1].state.id
    finally
        RC_GUI.shutdown!(win)
    end
end

@testset "rank count: a positive start-up count opens an MPI tab, and nothing without a count" begin
    win = RC_GUI.WindowState("", nothing, nothing)
    RC_GUI.open_startup_tab!(win)
    @test isempty(win.tabs.tabs)
    @test win.props["askLaunch"] == true
    @test_throws "there are no MPI ranks to launch" RC_GUI.open_mpi_tab!(win)
    win0 = RC_GUI.WindowState("", nothing, 0)
    @test_throws "there are no MPI ranks to launch" RC_GUI.open_mpi_tab!(win0)
    @test isempty(win0.tabs.tabs)
end

@testset "rank count: start-up counts are nothing, 0 or positive, and invalid values are rejected" begin
    @test MPIEnsemble.check_startup_count(nothing) === nothing
    @test MPIEnsemble.check_startup_count(0) === 0
    @test MPIEnsemble.check_startup_count(3) === 3
    for bad in (-2, 1.5, "3", true)
        @test_throws "rank count must be a non-negative integer (0 for a serial Julia REPL)" begin
            MPIEnsemble.check_startup_count(bad)
        end
    end
end

@testset "rank count: invalid values are rejected before a window opens" begin
    for bad in (-2, 1.5, "3", true)
        @test_throws "rank count must be a non-negative integer" MPIEnsemble.run_single_repl(rank_count = bad)
    end
end
