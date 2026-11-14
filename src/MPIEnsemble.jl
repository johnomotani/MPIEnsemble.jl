"""
    MPIEnsemble

A window of per-rank terminal panes for interactive MPI work in Julia.
"""
module MPIEnsemble

export run_single_repl

include("RankSpec.jl")
using .RankSpec: parse_rank_count

include("Pty.jl")
include("KeyMap.jl")
include("VTParse.jl")
include("LineLog.jl")
include("PtyOutput.jl")
include("ReplSession.jl")
include("PaneModel.jl")
include("ReplPane.jl")
include("TabSet.jl")

const GUI_FILE = joinpath(@__DIR__, "Gui.jl")

# Include Gui.jl on first use and return the named function from it. Loading
# MPIEnsemble does not load QML's Qt libraries, so the headless tests run
# without a display. The binding is read with getfield so that it is not
# compiled as a static reference to a module defined after this method.
function gui_function(name::Symbol)
    isdefined(@__MODULE__, :Gui) || Base.include(@__MODULE__, GUI_FILE)
    gui = Base.invokelatest(getfield, @__MODULE__, :Gui)
    return Base.invokelatest(getfield, gui, name)
end

# `tall_rows` must be `nothing` or a positive integer. Its value is returned unchanged.
function check_tall_rows(tall_rows)
    tall_rows === nothing && return nothing
    if !(tall_rows isa Integer) || tall_rows isa Bool || tall_rows < 1
        throw(ArgumentError("tall_rows must be nothing or a positive integer, got $(repr(tall_rows))"))
    end
    return Int(tall_rows)
end

"""
    run_single_repl(; startup_input = "", tall_rows = nothing) -> Nothing

Open the window, with one REPL tab, and block until it is closed. See `Gui.run_single_repl`, which this
loads on first use. Opening a window needs a display. Arguments are checked before the GUI code is loaded,
so invalid ones are reported without a display.
"""
function run_single_repl(; tall_rows = nothing, kwargs...)
    tall = check_tall_rows(tall_rows)
    return Base.invokelatest(gui_function(:run_single_repl); tall_rows = tall, kwargs...)
end

# Environment variable that sets `tall_rows` for the single-REPL window.
const TALL_ROWS_ENV = "MPIENSEMBLE_TALL_PTY_ROWS"

# The `tall_rows` setting from `TALL_ROWS_ENV`, or `nothing` when it is not set. A set value must be
# a positive integer.
function tall_rows_from_env()
    haskey(ENV, TALL_ROWS_ENV) || return nothing
    value = ENV[TALL_ROWS_ENV]
    n = tryparse(Int, value)
    (n !== nothing && n >= 1) ||
        throw(ArgumentError("$TALL_ROWS_ENV must be a positive integer, got \"$value\""))
    return n
end

"""
    main(args = ARGS) -> Int

Run MPIEnsemble. With no arguments, open the single-REPL window and block
until it is closed. The window's pseudo-terminal is sized to the pane unless
the environment variable `MPIENSEMBLE_TALL_PTY_ROWS` is set to a positive
integer, which gives it that many rows or the pane's rows if more; see
`Gui.run_single_repl`. `args` may instead hold one positive integer, the number
of MPI ranks; that path only prints the requested rank count and opens no
window.
Throws `ArgumentError` on invalid arguments or an invalid environment variable.
Returns the process exit code, `0`.
"""
function main(args = ARGS)
    nranks = parse_rank_count(args)
    if nranks === nothing
        tall_rows = tall_rows_from_env()
        Base.invokelatest(gui_function(:run_single_repl); tall_rows)
    else
        println("MPIEnsemble: MPI with $nranks rank(s) (no window yet)")
    end
    return 0
end

# Marks `main` as the entry point for `julia -m MPIEnsemble`. It must be a
# standalone statement: `(@main)(args) = ...` would define a second `main`.
@main

end # module MPIEnsemble
