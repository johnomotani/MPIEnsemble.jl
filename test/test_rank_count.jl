# The rank count from the command line or the rank dialog, as recorded in the window state. The state is
# built without opening a window. Loading the Gui module needs a Qt platform plugin, so the offscreen one
# is used, and no window is shown.
withenv("QT_QPA_PLATFORM" => "offscreen") do
    MPIEnsemble.gui_function(:run_single_repl)
end
const RC_GUI = Base.invokelatest(getfield, MPIEnsemble, :Gui)

@testset "rank count: an argument is recorded and no dialog is asked for" begin
    win = RC_GUI.WindowState("", nothing, 3)
    @test RC_GUI.rank_count(win) == 3
    @test win.props["askRanks"] == false
end

@testset "rank count: without an argument the window asks for it" begin
    win = RC_GUI.WindowState("", nothing, nothing)
    @test RC_GUI.rank_count(win) === nothing
    @test win.props["askRanks"] == true
end

@testset "rank count: the dialog's value is recorded once" begin
    win = RC_GUI.WindowState("", nothing, nothing)
    RC_GUI.set_rank_count!(win, 4)
    @test RC_GUI.rank_count(win) == 4
    @test win.props["askRanks"] == false
    @test_throws "already has a rank count of 4" RC_GUI.set_rank_count!(win, 5)
    @test RC_GUI.rank_count(win) == 4
end

@testset "rank count: an invalid dialog value is an error and records nothing" begin
    win = RC_GUI.WindowState("", nothing, nothing)
    @test_throws "rank count must be a positive integer" RC_GUI.set_rank_count!(win, 0)
    @test RC_GUI.rank_count(win) === nothing
    @test win.props["askRanks"] == true
end

@testset "rank count: cancelling the dialog records nothing and closes the window" begin
    win = RC_GUI.WindowState("", nothing, nothing)
    RC_GUI.cancel_rank_dialog!(win)
    @test RC_GUI.rank_count(win) === nothing
    @test win.props["askRanks"] == false
    @test win.props["closeRequest"] == 1
end

@testset "rank count: invalid values are rejected before a window opens" begin
    for bad in (0, -2, 1.5, "3", true)
        @test_throws "rank count must be a positive integer" MPIEnsemble.run_single_repl(rank_count = bad)
    end
end
