# Lifecycle of the REPL child shown in a pane: start, end detection, exit status and restart. This
# file does not use QML, so the lifecycle can be tested with real child processes without a display.
#
# A session is open from `start!` or `restart!` until its end is logged. The end is detected when the
# child has exited and its output has been read to the end. The open session is then released in full
# (its transport closed, its queued output fed to the log, its writer task finished) before
# `has_ended` reports true, so that a restart never overlaps the previous session.
#
# The child is either a pseudo-terminal that the REPL spawns, or the julia of one MPI rank, reached
# over that rank's launcher connection. The transport functions below are the only code that differs
# between the two; the rest of this file is shared.
module ReplSession

import ..Pty
import ..PtyOutput
import ..MpiLauncher
using ..VTParse: Terminal, resize_screen!
using ..LineLog: RankLog, begin_session!, end_session!, feed_output!, close_log!

export ExitInfo, exit_info, describe_exit, julia_repl_command, Repl, has_ended, is_started,
    start!, restart!, set_size!, feed_chunks!, poll_exit!, pump!, check_errors, send!, interrupt!,
    shutdown!

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

# The julia of one MPI rank, as seen by a REPL. The launcher's connection carries the rank's output as
# DATA frames and ends with an EXIT frame. Its terminal is resized with RESIZE frames, and interrupted with
# SIGNAL frames; the launcher does not restart it.
"""
    ConnectionTransport(connection, rows, cols)

The transport of a REPL over one rank's launcher connection (see `Repl(log, connection; rows, cols)`).
`rows` and `cols` are the size of the rank's terminal, as the launcher set it and as later resizes
queued for it set it. `exit` is the rank's exit status, which the output reader sets when the rank's
EXIT frame arrives. It stays `nothing` if the connection is closed before then.
"""
mutable struct ConnectionTransport
    const connection::MpiLauncher.RankConnection
    rows::Int
    cols::Int
    exit::Union{Nothing, ExitInfo}
end

# Items that the input channel carries to a connection's writer, besides input bytes. They are queued,
# as input is, so that the GUI thread never writes to the socket: a write waits while the wrapper is
# busy, and the wrapper's output then waits for the reader, which only the GUI thread drains.
struct ConnectionInterrupt end

struct ConnectionResize
    rows::Int
    cols::Int
end

function check_size(rows::Integer, cols::Integer)
    rows >= 1 && cols >= 1 || throw(ArgumentError("the size must be at least 1 by 1, got $rows by $cols"))
    return nothing
end

# Start the transport for a session of `source`, with a terminal of `rows` by `cols`. A pseudo-terminal
# is spawned at that size. A connection's terminal was set by the launcher, so a RESIZE is queued on
# `input` only if the size differs from it.
open_transport(command::Cmd, _, rows::Integer, cols::Integer) = Pty.spawn(command; rows, cols)

function open_transport(transport::ConnectionTransport, input::Channel, rows::Integer, cols::Integer)
    resize_transport!(transport, input, rows, cols)
    return transport
end

# Resize the terminal of an open session. A pseudo-terminal is resized at once. A connection's resize is
# queued on `input`, and nothing is queued when the size is already the one set.
function resize_transport!(session::Pty.Session, _, rows::Integer, cols::Integer)
    resize!(session, rows, cols)
    return nothing
end

function resize_transport!(transport::ConnectionTransport, input::Channel, rows::Integer, cols::Integer)
    (transport.rows, transport.cols) == (rows, cols) && return nothing
    put!(input, ConnectionResize(rows, cols))
    transport.rows = Int(rows)
    transport.cols = Int(cols)
    return nothing
end

# The item that interrupts the session's julia. In a terminal, Ctrl+C (byte 0x03) makes the terminal
# send SIGINT to the foreground process; a connection sends a SIGNAL frame instead.
interrupt_item(::Pty.Session) = UInt8[0x03]
interrupt_item(::ConnectionTransport) = ConnectionInterrupt()

# Output of the session, as a `PtyOutput.Output`, so that it is fed to the log in the same way for both
# transports. A connection's reader takes DATA frames and stops at its EXIT frame, which sets `exit`. If
# the connection closes without one, the reader's error is stored for `check_error`.
start_output(session::Pty.Session) = PtyOutput.start_reader(session)

function start_output(transport::ConnectionTransport)
    return PtyOutput.start_reader_from() do
        while true
            frame = MpiLauncher.take_frame!(transport.connection)
            if frame.type == MpiLauncher.T_EXIT
                code, signal = MpiLauncher.exit_status(frame)
                transport.exit = ExitInfo(code, signal)
                return nothing
            end
            isempty(frame.payload) || return frame.payload
        end
    end
end

# Writer task for the session's input: takes items from `input` in order until it is closed. Errors are
# stored in `errors[]`, as `PtyOutput.start_writer` does, unless `closing()` is true. For a connection, a
# write to a socket that the wrapper has closed is also dropped, since the reader then reports how the
# rank ended.
start_input(session::Pty.Session, input::Channel, errors::Base.RefValue{Any}, closing) =
    PtyOutput.start_writer(session, input, errors, closing)

function start_input(transport::ConnectionTransport, input::Channel, errors::Base.RefValue{Any}, closing)
    connection = transport.connection
    return @async begin
        try
            for item in input
                write_item!(connection, item)
            end
        catch err
            (closing() || peer_closed(err)) || (errors[] = err)
        end
    end
end

write_item!(connection::MpiLauncher.RankConnection, bytes::Vector{UInt8}) = MpiLauncher.send_input!(connection, bytes)
write_item!(connection::MpiLauncher.RankConnection, ::ConnectionInterrupt) = MpiLauncher.send_interrupt!(connection)
write_item!(connection::MpiLauncher.RankConnection, resize::ConnectionResize) =
    MpiLauncher.send_resize!(connection, resize.rows, resize.cols)

# Whether `err`, from writing to a rank's socket, means that the wrapper has closed its end. Depending on
# timing, the write fails with EPIPE, with ECONNRESET, or, once the reader has seen end of file, with an
# IOError that Julia reports as "stream is closed or unusable" (code 0). Every IOError from the socket is
# therefore that the wrapper has closed it, and the connection's reader reports how the rank ended.
peer_closed(err) = err isa Base.IOError

# Whether the session's child has ended: a process has exited, or a connection has delivered its EXIT frame.
transport_ended(session::Pty.Session) = process_exited(session.process)
transport_ended(transport::ConnectionTransport) = transport.exit !== nothing

# The exit status of an ended session, or `nothing` for a connection that has not delivered one.
transport_exit(session::Pty.Session) = exit_info(session.process)
transport_exit(transport::ConnectionTransport) = transport.exit

# Release the transport when the session is closed. A connection is left open, since its job owns it
# and stops the rank when the job is shut down (see `MpiLauncher.shutdown!`).
close_transport!(session::Pty.Session) = close(session)
close_transport!(::ConnectionTransport) = nothing

# Feed the output that is still to be read when a session is closed. A pseudo-terminal's reader ends
# once the pseudo-terminal is closed, so it is waited for. A connection's reader ends only at the rank's
# EXIT frame. A rank that is still running keeps its output, which is not fed to this log any more.
await_output!(feed, ::Pty.Session, output::PtyOutput.Output) = PtyOutput.wait_reader!(feed, output)

function await_output!(feed, transport::ConnectionTransport, output::PtyOutput.Output)
    if transport_ended(transport)
        PtyOutput.wait_reader!(feed, output)
    else
        PtyOutput.feed_chunks!(feed, output)
    end
    return nothing
end

"""
    Repl(log, command::Cmd)

The REPL child `command` and its output, which is appended to `log` for each session. Sessions are
started with `start!`, and a finished one is replaced with `restart!`.

    Repl(log, connection::MpiLauncher.RankConnection; rows, cols)

The julia of one MPI rank, reached over `connection`, with its output appended to `log`. `rows` and
`cols` are the size the launcher gave the rank's terminal. Such a REPL is started with `start!` like any
other, but cannot be restarted: `restart!` throws, since the rank's job is restarted as a whole.

`rows` and `cols` are the size of the current pseudo-terminal and screen. `exit` holds the exit status
of the last session once it has ended, and is `nothing` while the REPL has not started or is running.
Use `has_ended`, not the fields, to ask whether the REPL has ended.
"""
mutable struct Repl
    const log::RankLog
    const source::Union{Cmd, ConnectionTransport}
    const writer_error::Ref{Any}
    closing::Bool
    rows::Int
    cols::Int
    # The transport of the open session, or of the last one: a `Pty.Session`, or the `ConnectionTransport`.
    session::Union{Nothing, Pty.Session, ConnectionTransport}
    term::Union{Nothing, Terminal}
    output::Union{Nothing, PtyOutput.Output}
    input::Union{Nothing, Channel{Any}}
    writer::Union{Nothing, Task}
    exit::Union{Nothing, ExitInfo}
    # Whether the current session is open: started, and its end not yet appended to the log.
    open::Bool
end

function Repl(log::RankLog, source::Union{Cmd, ConnectionTransport})
    return Repl(log, source, Ref{Any}(nothing), false, 0, 0, nothing, nothing, nothing, nothing,
        nothing, nothing, false)
end

function Repl(log::RankLog, connection::MpiLauncher.RankConnection; rows::Integer, cols::Integer)
    check_size(rows, cols)
    return Repl(log, ConnectionTransport(connection, Int(rows), Int(cols), nothing))
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
    repl.source isa ConnectionTransport && error("this REPL runs in an MPI rank over a launcher " *
        "connection, so it cannot be restarted: the rank's job is restarted as a whole")
    info = repl.exit
    info === nothing && error("the REPL is still running, so it cannot be restarted")
    open_session!(repl, describe_exit(info))
    repl.exit = nothing
    return repl
end

function open_session!(repl::Repl, previous::AbstractString)
    input = Channel{Any}(Inf)
    session = open_transport(repl.source, input, repl.rows, repl.cols)
    term = begin_session!(repl.log, time_ns(), repl.rows, repl.cols; previous)
    repl.session = session
    repl.term = term
    repl.output = start_output(session)
    repl.input = input
    repl.writer = start_input(session, input, repl.writer_error, () -> repl.closing)
    repl.open = true
    return repl
end

"""
    set_size!(repl, rows, cols)

Set the size of the screen and, while a session is open, of its terminal. The screen of the last session
is resized even after it has ended, since it stays on display.
"""
function set_size!(repl::Repl, rows::Integer, cols::Integer)
    check_size(rows, cols)
    repl.rows = Int(rows)
    repl.cols = Int(cols)
    t = repl.term
    if t !== nothing && (t.rows, t.cols) != (rows, cols)
        resize_screen!(t, rows, cols)
    end
    if repl.open
        resize_transport!(repl.session, something(repl.input), rows, cols)
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
    transport_ended(repl.session) || return false
    close_session!(repl)
    return true
end

# Release the open session: close its input and transport (which ends a pseudo-terminal's child if it is
# still running), feed the output that is still queued to the log, and append the end of the session to
# the log. Output that the reader has not yet taken is fed before the log is ended, since the reader
# blocks on a full queue until it is taken.
function close_session!(repl::Repl)
    close(something(repl.input))
    close_transport!(repl.session)
    await_output!(bytes -> feed_bytes!(repl, bytes), repl.session, repl.output)
    wait(repl.writer)
    end_session!(repl.log, repl.term, time_ns())
    repl.open = false
    repl.exit === nothing && (repl.exit = transport_exit(repl.session))
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
    interrupt!(repl) -> Bool

Interrupt the open session's julia, as Ctrl+C does in a terminal. The interrupt is queued behind the
input already sent. Returns `false`, sending nothing, once the session has ended.
"""
function interrupt!(repl::Repl)
    repl.open || return false
    put!(something(repl.input), interrupt_item(repl.session))
    return true
end

"""
    shutdown!(repl)

Close the window's session. A pseudo-terminal's child is asked to exit, and then killed after a timeout
(see `Pty.close`). A connection's rank is not stopped here: its job stops it (see `MpiLauncher.shutdown!`),
so a rank still running when this is called does not get an exit status, and `has_ended` stays false.
The log is completed and closed. Throws the error of a task that failed.
"""
function shutdown!(repl::Repl)
    repl.closing = true
    repl.open && close_session!(repl)
    repl.term === nothing || close_log!(repl.log)
    check_errors(repl)
    return nothing
end

end # module ReplSession
