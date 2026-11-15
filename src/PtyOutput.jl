# Output of a pseudo-terminal session, read by a task into a bounded queue; input to the session,
# written by a task from a queue; and replies to the session's terminal queries, queued as input.
#
# The reader task moves what the session writes into `chunks`, one chunk per read. The queue holds at
# most `MAX_QUEUED_CHUNKS` chunks. When the consumer falls behind, the reader blocks in `put!`, the
# pseudo-terminal's buffer fills, and the child blocks on its write. The consumer must therefore keep
# taking chunks while it waits for the reader to finish; `wait_reader!` does so.
module PtyOutput

using ..Pty: read_output!, Session
using ..VTParse: Terminal, take_replies!

export Output, start_reader, start_reader_from, feed_chunks!, wait_reader!, check_error, finished, start_writer,
    queue_replies!, session_ended

# Chunks held between the reader and the consumer. A chunk is what one read of the pseudo-terminal
# returned, at most `READ_SIZE` bytes, so this bounds the output held in memory to about 1 MB.
const MAX_QUEUED_CHUNKS = 256
const READ_SIZE = 4096

# Pause before reading again when no output is ready.
const READ_POLL_INTERVAL = 0.002

"""
    Output

The queue `chunks` of output read from a session, the task `reader` that fills it, and the error
that ended the reader, if any, in `error`. The reader closes `chunks` when it finishes, after
storing any error.
"""
struct Output
    chunks::Channel{Vector{UInt8}}
    reader::Task
    error::Base.RefValue{Any}
end

"""
    start_reader(session) -> Output

Start a task that reads `session` until its output ends and queues each read as a chunk. The end of
output is the `-1` that `Pty.read_output!` returns. Any error is stored in the returned `Output`, for
`check_error`.
"""
function start_reader(session)
    buf = Vector{UInt8}(undef, READ_SIZE)
    return start_reader_from() do
        n = read_output!(session, buf)
        n < 0 && return nothing
        return n == 0 ? UInt8[] : buf[1:n]
    end
end

"""
    start_reader_from(read_chunk) -> Output

Start a task that calls `read_chunk()` repeatedly and queues each chunk it returns, until `read_chunk`
returns `nothing`, which ends the output. An empty chunk means that none is ready: the task pauses
briefly and calls again. An error thrown by `read_chunk` is stored in the returned `Output`, for
`check_error`.
"""
function start_reader_from(read_chunk)
    chunks = Channel{Vector{UInt8}}(MAX_QUEUED_CHUNKS)
    err = Ref{Any}(nothing)
    task = @async begin
        try
            while true
                chunk = read_chunk()
                chunk === nothing && break
                if isempty(chunk)
                    sleep(READ_POLL_INTERVAL)
                else
                    put!(chunks, chunk)
                end
            end
        catch e
            err[] = e
        finally
            close(chunks)
        end
    end
    return Output(chunks, task, err)
end

"""
    check_error(out::Output)

Rethrow the error that ended the reader, if there was one.
"""
function check_error(out::Output)
    err = out.error[]
    err === nothing || throw(err)
    return nothing
end

"""
    finished(out::Output) -> Bool

Whether the reader has finished and every chunk has been taken.
"""
finished(out::Output) = !isopen(out.chunks) && !isready(out.chunks)

"""
    feed_chunks!(feed, out::Output, more = () -> true) -> Bool

Pass the queued chunks to `feed`, in order, without waiting for more. Before each chunk, `more()`
must return true. Returns whether any chunk was fed.
"""
function feed_chunks!(feed, out::Output, more = () -> true)
    fed = false
    while isready(out.chunks) && more()
        feed(take!(out.chunks))
        fed = true
    end
    return fed
end

"""
    wait_reader!(feed, out::Output)

Wait until the reader has finished, passing each chunk to `feed` as it is queued, so that the reader
is never blocked on a full queue. Returns once the queue is closed and empty. The session must be
closed before this is called, or the reader may not finish.
"""
function wait_reader!(feed, out::Output)
    ch = out.chunks
    while true
        if isready(ch)
            feed(take!(ch))
        elseif isopen(ch)
            try
                wait(ch)
            catch e
                # `wait` throws when the channel is closed while it waits. The loop then ends.
                e isa InvalidStateException || rethrow()
            end
        else
            return nothing
        end
    end
end

"""
    start_writer(session, input, errors, closing) -> Task

Start a task that writes each chunk taken from the channel `input` to `session`, in the order they
were queued, until `input` is closed. A write error is stored in `errors[]`, which the caller checks,
unless the session is closed, the child has closed its side (see `session_ended`), or `closing()`
returns true. Those errors are dropped: the session has ended, or the caller no longer wants output.
"""
function start_writer(session::Session, input::Channel, errors::Base.RefValue{Any}, closing)
    return @async begin
        try
            for bytes in input
                write(session, bytes)
            end
        catch err
            (!isopen(session) || session_ended(err) || closing()) || (errors[] = err)
        end
    end
end

"""
    session_ended(err) -> Bool

Whether `err`, from writing to a session, means that the child has closed its side of the
pseudo-terminal.
"""
session_ended(err) = (err isa Base.IOError && err.code == Base.UV_EIO) ||
    (err isa SystemError && err.errnum == Int(Libc.EIO))

"""
    queue_replies!(input, writer, term)

Move the replies that `term` has produced since the last call onto `input`, to be written by the
writer task, `writer`. This does not change the pane or the following state, since replies are not
input from the user. If `input` is closed or `writer` has finished, the replies are dropped: the
window is closing or the child has gone, so nothing can read them. A write error other than the
child's end is kept by the writer for its caller, as in `start_writer`.
"""
function queue_replies!(input::Channel, writer, term::Terminal)
    bytes = take_replies!(term)
    isempty(bytes) && return nothing
    (isopen(input) && !istaskdone(writer)) || return nothing
    put!(input, bytes)
    return nothing
end

end # module PtyOutput
