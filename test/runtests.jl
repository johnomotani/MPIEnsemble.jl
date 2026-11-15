using Test
using MPIEnsemble

@testset "MPIEnsemble" begin
    include("test_rankspec.jl")
    include("test_main.jl")
    include("test_gui.jl")
    include("test_pty.jl")
    include("test_pty_output.jl")
    include("test_repl_session.jl")
    include("test_repl_edit.jl")
    include("test_keymap.jl")
    include("test_vtparse.jl")
    include("test_linelog.jl")
    include("test_panemodel.jl")
    include("test_selection.jl")
    include("test_tall_rows.jl")
    include("test_scrollbar.jl")
    include("test_tabset.jl")
    include("test_repl_pane.jl")
    include("test_rank_count.jl")
    include("test_wrapper.jl")
end
