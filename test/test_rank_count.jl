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

@testset "rank count: invalid values are rejected before a window opens" begin
    for bad in (0, -2, 1.5, "3", true)
        @test_throws "rank count must be a positive integer" MPIEnsemble.run_single_repl(rank_count = bad)
    end
end
