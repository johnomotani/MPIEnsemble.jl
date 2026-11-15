# The state of one REPL tab: its log, its pane onto the log, and the REPL session that writes to the
# log. This file does not use QML. The window (Gui.jl) wraps each state with the QML objects that show
# its pane.
#
# A tab is visible or hidden. A hidden tab's session is still read and its output appended to the log,
# but its pane is neither refilled nor reported: `set_visible!` refills it when it is shown.
module ReplPane

import ..ReplSession
import ..MpiLauncher
using ..ReplSession: Repl, is_started
using ..LineLog: RankLog
using ..VTParse: screen_lines
using ..PaneModel: Pane, attach!, set_screen_rows!, set_view_rows!, refresh!, resume_following!

export State, set_visible!, size!, feed!, send_input!, restart!, shutdown!

# `screen_lines` removes trailing spaces, so the prompt is matched without its final space.
const PROMPT = "julia>"

"""
    State(command, startup_input, tall_rows; changed = () -> nothing)

The log, pane and REPL of one tab, which runs `command`. `startup_input` is written to the first
session's terminal when its first prompt appears, and is empty for tabs that do not need it. `tall_rows`
is `nothing` or the number of rows for the terminal and the screen model (see `Gui.run_single_repl`).

    State(connection::MpiLauncher.RankConnection, rows, cols; changed = () -> nothing)

The log, pane and REPL of one MPI rank, whose julia is reached over `connection`. `rows` and `cols` are the
terminal size the launcher gave the rank. Its session is restarted over a new connection (see `restart!`).

`changed` is called with no arguments when the pane's rows are refilled while the tab is visible, so
that the caller can publish them. `visible` is false until `set_visible!` says otherwise, and no
session is started until the pane is sized (see `size!`).
"""
mutable struct State
    const log::RankLog
    const pane::Pane
    const repl::Repl
    const startup_input::String
    const tall_rows::Union{Nothing, Int}
    const changed::Function
    visible::Bool
    # Set whenever the pane is refilled. The caller reads and clears it when it updates what it shows.
    refilled::Bool
    prompt_seen::Bool
end

function State(command::Cmd, startup_input::AbstractString, tall_rows::Union{Nothing, Int};
        changed = () -> nothing)
    log = RankLog(0)
    return build(log, Repl(log, command), String(startup_input), tall_rows, changed)
end

function State(connection::MpiLauncher.RankConnection, rows::Integer, cols::Integer;
        changed = () -> nothing)
    log = RankLog(0)
    return build(log, Repl(log, connection; rows, cols), "", nothing, changed)
end

function build(log::RankLog, repl::Repl, startup_input::String, tall_rows::Union{Nothing, Int}, changed)
    holder = Ref{Any}(nothing)
    pane = Pane(log, 1; notify = (p, kind, first, last) -> refilled!(holder[], kind))
    st = State(log, pane, repl, startup_input, tall_rows, changed, false, false, false)
    holder[] = st
    return st
end

function refilled!(st::State, kind::Symbol)
    kind === :change || error("unexpected pane notification $kind")
    st.refilled = true
    st.visible && st.changed()
    return nothing
end

# Rows of the pseudo-terminal and the screen model for a pane of `pane_rows` rows.
session_rows(st::State, pane_rows::Int) = st.tall_rows === nothing ? pane_rows : max(st.tall_rows, pane_rows)

"""
    set_visible!(st, visible::Bool)

Show or hide the tab's pane. Showing it refills the pane, so that it reflects the output read while it
was hidden.
"""
function set_visible!(st::State, visible::Bool)
    st.visible == visible && return st
    st.visible = visible
    if visible
        refresh!(st.pane)
        st.refilled = true
        st.changed()
    end
    return st
end

"""
    size!(st, pane_rows, cols)

Set the pane's visible rows and the session's size to `pane_rows` rows of the pane and `cols` columns.
The first call starts the session at that size. Later calls resize it.
"""
function size!(st::State, pane_rows::Integer, cols::Integer)
    rows = session_rows(st, Int(pane_rows))
    set_view_rows!(st.pane, pane_rows)
    if is_started(st.repl)
        if (st.repl.rows, st.repl.cols) != (rows, cols)
            ReplSession.set_size!(st.repl, rows, cols)
            set_screen_rows!(st.pane, rows)
        end
    else
        set_screen_rows!(st.pane, rows)
        ReplSession.start!(st.repl, rows, cols)
        attach!(st.pane, st.repl.term)
    end
    return st
end

"""
    feed!(st, max_lines) -> Int

Feed the output queued by the session's reader to the log, appending at most about `max_lines` lines,
and end the session if its child has exited. A visible pane is refreshed when anything changed. Returns
the number of lines appended.
"""
function feed!(st::State, max_lines::Integer)
    ReplSession.check_errors(st.repl)
    n0 = length(st.log)
    if ReplSession.feed_chunks!(st.repl, Int(max_lines))
        st.prompt_seen || check_prompt!(st)
        st.visible && refresh!(st.pane)
    end
    if ReplSession.poll_exit!(st.repl)
        st.visible && refresh!(st.pane)
    end
    return length(st.log) - n0
end

function check_prompt!(st::State)
    any(l -> occursin(PROMPT, l), screen_lines(st.repl.term)) || return nothing
    st.prompt_seen = true
    isempty(st.startup_input) || ReplSession.send!(st.repl, Vector{UInt8}(codeunits(st.startup_input)))
    return nothing
end

"""
    send_input!(st, bytes) -> Bool

Send `bytes` to the session and return the pane to the bottom of the output. Returns `false`, doing
nothing else, when the session has ended.
"""
function send_input!(st::State, bytes::Vector{UInt8})
    ReplSession.send!(st.repl, bytes) || return false
    resume_following!(st.pane)
    return true
end

"""
    restart!(st)

Start a new session in the pane after the previous one has ended (see `ReplSession.restart!`). The
pane follows the new output.
"""
function restart!(st::State)
    ReplSession.restart!(st.repl)
    return restart_pane!(st)
end

"""
    restart!(st, connection::MpiLauncher.RankConnection; rows, cols)

Start a new session of an MPI rank's julia over `connection`, a new job's connection for the rank, in
the same pane. The old output stays in the log, and the pane follows the new output (see
`ReplSession.restart!`). `rows` and `cols` are the size the launcher gave the connection.
"""
function restart!(st::State, connection::MpiLauncher.RankConnection; rows::Integer, cols::Integer)
    ReplSession.restart!(st.repl, connection; rows, cols)
    return restart_pane!(st)
end

# Show the terminal of a session that has just started in the pane, which follows its output.
function restart_pane!(st::State)
    st.prompt_seen = true
    attach!(st.pane, st.repl.term)
    resume_following!(st.pane)
    return st
end

"""
    shutdown!(st)

Close the tab's session and complete its log (see `ReplSession.shutdown!`). Its pane is not refilled
after this.
"""
function shutdown!(st::State)
    st.visible = false
    ReplSession.shutdown!(st.repl)
    return nothing
end

end # module ReplPane
