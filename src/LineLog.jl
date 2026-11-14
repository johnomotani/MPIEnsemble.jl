# Per-rank output log: lines with arrival times, one writer and any number of readers.
#
# The writer owns the parser state of the open session and calls `feed_output!` with each chunk of
# bytes. Lines are appended to the log under a lock when they leave the screen (see `VTParse`), and
# the live row is replaced. Readers call `window`, `await_length` or `visible` from other tasks or
# threads. Entries are never removed or changed once appended.
module LineLog

using ..VTParse: Terminal, LogLine, Style, feed!, flush!, take_lines!, live_line, counters

export LogEntry, SessionReport, RankLog, LogView, begin_session!, end_session!, feed_output!,
    close_log!, window, await_length, live_row, session_reports, follow_bottom!, scroll_to!,
    on_append!, visible

"""
    LogEntry

One entry of a rank's log. `kind` is `:line` for a line, with `text` and `spans` as in
`VTParse.LogLine`, or `:restart` for the boundary between two sessions, which has empty `text`.
`session` is the session the entry belongs to; `t_ns` is the arrival time of the bytes that
made the entry leave the screen (or, for lines appended when the session ends, the time of the end).
`nrows` is the number of screen rows the entry was made from, and 0 for a restart entry. The text of
a restart entry describes how the previous session ended, and is empty when it is not known.
"""
struct LogEntry
    rank::Int
    session::Int
    t_ns::UInt64
    kind::Symbol
    text::String
    spans::Vector{Tuple{UnitRange{Int}, Style}}
    nrows::Int
end

"""
    SessionReport

Counts for one finished session: ignored sequences by name, queries answered by name, writes into
emitted rows, and text that was removed from the screen without being logged.
"""
struct SessionReport
    session::Int
    ignored::Dict{String, Int}
    answered::Dict{String, Int}
    rewrites::Int
    discarded::Int
end

"""
    RankLog(rank)

Append-only log of one rank across its sessions. Use `begin_session!`, `feed_output!` and
`end_session!` from the writer. Use `window`, `length`, `await_length` and `live_row` from readers.
"""
mutable struct RankLog
    const rank::Int
    const lock::ReentrantLock
    const changed::Threads.Condition
    entries::Vector{LogEntry}
    live::Union{Nothing, LogLine}
    session::Int                          # number of the most recent session; 0 before the first
    current::Union{Nothing, Terminal}     # parser of the open session
    reports::Vector{SessionReport}
    closed::Bool
end

function RankLog(rank::Integer)
    lock = ReentrantLock()
    return RankLog(Int(rank), lock, Threads.Condition(lock), LogEntry[], nothing, 0, nothing,
        SessionReport[], false)
end

Base.length(log::RankLog) = lock(() -> length(log.entries), log.lock)

"""
    begin_session!(log, t_ns, rows, cols) -> Terminal

Start a session with a new parser of the given size. Before the first session there is no restart
entry. A later session follows a `:restart` entry with the new session number, whose text is
`previous`, a description of how the previous session ended. The previous session must have ended with
`end_session!`.
"""
function begin_session!(log::RankLog, t_ns::Integer, rows::Integer, cols::Integer; previous::AbstractString = "")
    current = log.current
    current === nothing || error("session $(log.session) of rank $(log.rank) is still open; end it with end_session! first")
    log.closed && error("the log of rank $(log.rank) is closed")
    term = Terminal(rows, cols)
    lock(log.lock) do
        log.session += 1
        if log.session > 1
            push!(log.entries, LogEntry(log.rank, log.session, UInt64(t_ns), :restart, String(previous), Tuple{UnitRange{Int}, Style}[], 0))
        elseif !isempty(previous)
            error("the first session of rank $(log.rank) has no previous session")
        end
        notify(log.changed)
    end
    log.current = term
    return term
end

function check_open(log::RankLog, term::Terminal)
    term === log.current || error("the terminal is not the open session of rank $(log.rank)")
    return nothing
end

function append_lines!(log::RankLog, lines::Vector{LogLine})
    for L in lines
        push!(log.entries, LogEntry(log.rank, log.session, L.t_ns, :line, L.text, L.spans, L.nrows))
    end
    return nothing
end

"""
    feed_output!(log, term, bytes, t_ns)

Feed one chunk of bytes read from the session's process. Lines that leave the screen with the chunk
are appended with timestamp `t_ns`, and the live row is replaced. Replies to terminal queries are not
logged: they are left in `term` for `VTParse.take_replies!`.
"""
function feed_output!(log::RankLog, term::Terminal, bytes::AbstractVector{UInt8}, t_ns::Integer)
    check_open(log, term)
    feed!(term, bytes, UInt64(t_ns))
    lines = take_lines!(term)
    live = live_line(term)
    lock(log.lock) do
        append_lines!(log, lines)
        log.live = live
        notify(log.changed)
    end
    return log
end

"""
    end_session!(log, term, t_ns)

End the session when its process has exited. The lines still on the screen that hold text are
appended, as `VTParse.flush!` does, and the session's counts are stored in `session_reports(log)`.
"""
function end_session!(log::RankLog, term::Terminal, t_ns::Integer)
    check_open(log, term)
    flush!(term, UInt64(t_ns))
    lines = take_lines!(term)
    c = counters(term)
    lock(log.lock) do
        append_lines!(log, lines)
        log.live = nothing
        push!(log.reports, SessionReport(log.session, c.ignored, c.answered, c.rewrites, c.discarded))
        notify(log.changed)
    end
    log.current = nothing
    return log
end

"""
    close_log!(log)

Mark the log as complete: no further sessions start, and `await_length` returns without waiting.
Throws if a session is still open.
"""
function close_log!(log::RankLog)
    log.current === nothing || error("session $(log.session) of rank $(log.rank) is still open")
    lock(log.lock) do
        log.closed = true
        notify(log.changed)
    end
    return log
end

"""
    window(log, idxs) -> Vector{LogEntry}

A copy of the entries at `idxs`. Throws `ArgumentError` if `idxs` is not within the log.
"""
function window(log::RankLog, idxs::AbstractUnitRange{<:Integer})
    return lock(log.lock) do
        n = length(log.entries)
        isempty(idxs) || (first(idxs) >= 1 && last(idxs) <= n) ||
            throw(ArgumentError("entries $idxs are outside the log of rank $(log.rank), which has $n entries"))
        log.entries[idxs]
    end
end

"""
    await_length(log, after) -> Int

Block until the log has more than `after` entries or is closed. Return the number of entries.
"""
function await_length(log::RankLog, after::Integer)
    return lock(log.lock) do
        while length(log.entries) <= after && !log.closed
            wait(log.changed)
        end
        length(log.entries)
    end
end

"""
    live_row(log) -> Union{LogLine, Nothing}

The logical line under the cursor in the open session, if it has not been appended and holds text,
or `nothing`. This is not an entry of the log.
"""
live_row(log::RankLog) = lock(() -> log.live, log.lock)

"""
    session_reports(log) -> Vector{SessionReport}

Counts for each session that has ended, in order.
"""
session_reports(log::RankLog) = lock(() -> copy(log.reports), log.lock)

"""
    LogView(log, height)

A window of `height` entries onto `log`. The view holds a position only and reads entries when
asked. It starts following the bottom of the log. Its methods must be called from one task at a
time.
"""
mutable struct LogView
    const log::RankLog
    const height::Int
    top::Int
    follow::Bool
end

function LogView(log::RankLog, height::Integer)
    height >= 1 || throw(ArgumentError("view height must be at least 1, got $height"))
    return follow_bottom!(LogView(log, Int(height), 1, true))
end

# Last position that shows the final entry.
last_top(view::LogView) = max(1, length(view.log) - view.height + 1)

function follow_bottom!(view::LogView)
    view.top = last_top(view)
    view.follow = true
    return view
end

function scroll_to!(view::LogView, top::Integer)
    last = last_top(view)
    view.top = clamp(Int(top), 1, last)
    view.follow = view.top == last
    return view
end

# Called after entries are appended. The view moves only while following.
on_append!(view::LogView) = view.follow ? follow_bottom!(view) : view

"""
    visible(view) -> Vector{LogEntry}

The entries in the view. Fewer than `height` entries are returned when the log is shorter.
"""
function visible(view::LogView)
    return lock(view.log.lock) do
        n = length(view.log.entries)
        hi = min(view.top + view.height - 1, n)
        view.top <= hi ? view.log.entries[view.top:hi] : LogEntry[]
    end
end

end # module
