# Lifecycle of the REPL child shown in a pane: start, end detection, exit status and restart. This
# file does not use QML, so the lifecycle can be tested with real child processes without a display.
#
# A session is open from `start!` or `restart!` until its end is logged. The end is detected when the
# child has exited and its output has been read to the end. The open session is then released in full
# (its pseudo-terminal closed, its queued output fed to the log, its writer task finished) before
# `has_ended` reports true, so that a restart never overlaps the previous session.
module ReplSession

import ..Pty
import ..PtyOutput
using ..VTParse: Terminal, resize_screen!
using ..LineLog: RankLog, begin_session!, end_session!, feed_output!, close_log!

export ExitInfo, exit_info, describe_exit, julia_repl_command, Repl, has_ended, is_started,
    start!, restart!, set_size!, feed_chunks!, poll_exit!, pump!, check_errors, send!, shutdown!

"""
    ExitInfo(code, signal)

How a child process ended. `signal` is the signal that terminated it, or 0 when it exited with
`code`. A process terminated by a signal has `code` 0.
"""
struct ExitInfo
    code::Int
    signal::Int
end

"""
    exit_info(process::Base.Process) -> ExitInfo

The exit status of a process that has exited. Reads the status directly, so a process killed by a
signal gives an `ExitInfo` rather than an error. Throws if the process is still running.
"""
function exit_info(process::Base.Process)
    process_exited(process) || error("the process has not exited")
    return ExitInfo(process.exitcode, process.termsignal)
end

# Names of the signals that a child is likely to die of on Linux. Other numbers are described by
# number alone.
const SIGNAL_NAMES = Dict(1 => "SIGHUP", 2 => "SIGINT", 3 => "SIGQUIT", 4 => "SIGILL", 6 => "SIGABRT",
    7 => "SIGBUS", 8 => "SIGFPE", 9 => "SIGKILL", 11 => "SIGSEGV", 13 => "SIGPIPE", 14 => "SIGALRM",
    15 => "SIGTERM")

"""
    describe_exit(info::ExitInfo) -> String

A sentence saying how the Julia process ended, such as `Julia exited with code 0` or
`Julia was killed by signal 9 (SIGKILL)`.
"""
function describe_exit(info::ExitInfo)
    info.signal == 0 && return "Julia exited with code $(info.code)"
    name = get(SIGNAL_NAMES, info.signal, nothing)
    name === nothing && return "Julia was killed by signal $(info.signal)"
    return "Julia was killed by signal $(info.signal) ($name)"
end

"""
    julia_repl_command() -> Cmd

The command that runs a Julia REPL with the same Julia executable as the current process.
"""
function julia_repl_command()
    argv = [Base.julia_cmd().exec...; "-q"; "--startup-file=no"]
    return addenv(Cmd(argv), "TERM" => "xterm-256color")
end

"""
    Repl(log, command)

The REPL child `command` and its output, which is appended to `log` for each session. Sessions are
started with `start!`, and a finished one is replaced with `restart!`.

`rows` and `cols` are the size of the current pseudo-terminal and screen. `exit` holds the exit status
of the last session once it has ended, and is `nothing` while the REPL has not started or is running.
Use `has_ended`, not the fields, to ask whether the REPL has ended.
"""
mutable struct Repl
    const log::RankLog
    const command::Cmd
    const writer_error::Ref{Any}
    closing::Bool
    rows::Int
    cols::Int
    session::Union{Nothing, Pty.Session}
    term::Union{Nothing, Terminal}
    output::Union{Nothing, PtyOutput.Output}
    input::Union{Nothing, Channel{Vector{UInt8}}}
    writer::Union{Nothing, Task}
    exit::Union{Nothing, ExitInfo}
    # Whether the current session is open: started, and its end not yet appended to the log.
    open::Bool
end

function Repl(log::RankLog, command::Cmd)
    return Repl(log, command, Ref{Any}(nothing), false, 0, 0, nothing, nothing, nothing, nothing,
        nothing, nothing, false)
end

"""
    has_ended(repl) -> Bool

Whether the REPL's session has ended and the end has been logged. Input is then not sent.
"""
has_ended(repl::Repl) = repl.exit !== nothing

"""
    is_started(repl) -> Bool

Whether a session has been started.
"""
is_started(repl::Repl) = repl.term !== nothing

"""
    start!(repl, rows, cols)

Start the first session, with a pseudo-terminal of `rows` by `cols` characters.
"""
function start!(repl::Repl, rows::Integer, cols::Integer)
    is_started(repl) && error("the REPL has already started; use restart! after it has ended")
    set_size!(repl, rows, cols)
    open_session!(repl, "")
    return repl
end

"""
    restart!(repl)

Start a new session at the current size of `repl`, once the previous one has ended. The restart is
marked in the log with the previous session's exit status. Throws if the REPL is running.
"""
function restart!(repl::Repl)
    info = repl.exit
    info === nothing && error("the REPL is still running, so it cannot be restarted")
    open_session!(repl, describe_exit(info))
    repl.exit = nothing
    return repl
end

function open_session!(repl::Repl, previous::AbstractString)
    session = Pty.spawn(repl.command; rows = repl.rows, cols = repl.cols)
    term = begin_session!(repl.log, time_ns(), repl.rows, repl.cols; previous)
    input = Channel{Vector{UInt8}}(Inf)
    repl.session = session
    repl.term = term
    repl.output = PtyOutput.start_reader(session)
    repl.input = input
    repl.writer = PtyOutput.start_writer(session, input, repl.writer_error, () -> repl.closing)
    repl.open = true
    return repl
end

"""
    set_size!(repl, rows, cols)

Set the size of the screen and, while a session is open, of its pseudo-terminal. The screen of the
last session is resized even after it has ended, since it stays on display.
"""
function set_size!(repl::Repl, rows::Integer, cols::Integer)
    rows >= 1 && cols >= 1 || throw(ArgumentError("the size must be at least 1 by 1, got $rows by $cols"))
    repl.rows = Int(rows)
    repl.cols = Int(cols)
    t = repl.term
    if t !== nothing && (t.rows, t.cols) != (rows, cols)
        resize_screen!(t, rows, cols)
    end
    if repl.open
        resize!(repl.session, rows, cols)
    end
    return repl
end

# Feed one chunk of output to the parser and log, then queue the replies to its queries. The replies
# go to the child without changing the pane (see `PtyOutput.queue_replies!`).
function feed_bytes!(repl::Repl, bytes::Vector{UInt8})
    feed_output!(repl.log, repl.term, bytes, time_ns())
    PtyOutput.queue_replies!(something(repl.input), something(repl.writer), repl.term)
    return nothing
end

"""
    feed_chunks!(repl, max_lines) -> Bool

Feed the output queued by the reader to the log. At most `max_lines` lines are appended, unless
`max_lines` is `nothing`. Returns whether any output was fed.
"""
function feed_chunks!(repl::Repl, max_lines)
    repl.output === nothing && return false
    n0 = length(repl.log)
    more = () -> max_lines === nothing || length(repl.log) - n0 < max_lines
    return PtyOutput.feed_chunks!(bytes -> feed_bytes!(repl, bytes), repl.output, more)
end

"""
    poll_exit!(repl) -> Bool

If the open session's child has exited and its output has been read to the end, end the session:
release it and log its end. Returns whether the session ended on this call.
"""
function poll_exit!(repl::Repl)
    repl.open || return false
    PtyOutput.finished(repl.output) || return false
    process_exited(repl.session.process) || return false
    close_session!(repl)
    return true
end

# Release the open session: close its input and pseudo-terminal (which ends the child if it is still
# running), feed the output that is still queued to the log, and append the end of the session to the
# log. Output that the reader has not yet taken is fed before the log is ended, since the reader
# blocks on a full queue until it is taken.
function close_session!(repl::Repl)
    close(something(repl.input))
    close(repl.session)
    PtyOutput.wait_reader!(bytes -> feed_bytes!(repl, bytes), repl.output)
    wait(repl.writer)
    end_session!(repl.log, repl.term, time_ns())
    repl.open = false
    repl.exit === nothing && (repl.exit = exit_info(repl.session.process))
    return nothing
end

"""
    pump!(repl)

Check for errors from the reader and writer tasks, feed all queued output to the log, and end the
session if its child has exited. Throws the error of a task that failed.
"""
function pump!(repl::Repl)
    check_errors(repl)
    feed_chunks!(repl, nothing)
    poll_exit!(repl)
    return repl
end

"""
    check_errors(repl)

Throw the error that ended the reader or writer task of the current session, if there was one.
"""
function check_errors(repl::Repl)
    repl.output === nothing || PtyOutput.check_error(repl.output)
    err = repl.writer_error[]
    err === nothing || throw(err)
    return nothing
end

"""
    send!(repl, bytes) -> Bool

Queue `bytes` for the open session's child. Returns `false`, sending nothing, once the session has
ended.
"""
function send!(repl::Repl, bytes::Vector{UInt8})
    repl.open || return false
    put!(something(repl.input), bytes)
    return true
end

"""
    shutdown!(repl)

Close the window's session: a running child is asked to exit, and then killed after a timeout (see
`Pty.close`). The log is completed and closed. Throws the error of a task that failed.
"""
function shutdown!(repl::Repl)
    repl.closing = true
    repl.open && close_session!(repl)
    repl.term === nothing || close_log!(repl.log)
    check_errors(repl)
    return nothing
end

end # module ReplSession
