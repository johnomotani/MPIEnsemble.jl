const PO_OUT = MPIEnsemble.PtyOutput
const PO_PTY = MPIEnsemble.Pty

# Number of chunks queued in `ch`. `Base.n_avail` also counts the reader's blocked `put!`, so the
# queue is measured directly: `data` is the buffer of a `Channel`.
po_queued(ch::Channel) = length(ch.data)

# Output of `seq 1 n` as the pseudo-terminal delivers it: each line ends with CR LF.
po_seq_bytes(n::Integer) = Vector{UInt8}(codeunits(join(string.(1:n), "\r\n") * "\r\n"))

# A source whose read fails with an error that is not the end of output.
struct PoFailingSource end
MPIEnsemble.Pty.read_output!(::PoFailingSource, ::Vector{UInt8}) = throw(ErrorException("read failed"))

@testset "a reader error other than end of output is kept for check_error" begin
    out = PO_OUT.start_reader(PoFailingSource())
    wait(out.reader)
    @test PO_OUT.finished(out)
    @test_throws "read failed" PO_OUT.check_error(out)
end

@testset "a burst of 200,000 lines through the bounded queue, drained slowly" begin
    n = 200_000
    s = PO_PTY.spawn(Cmd(["seq", "1", string(n)]); rows = 24, cols = 80)
    out = PO_OUT.start_reader(s)
    got = UInt8[]
    most = 0
    deadline = time() + 120
    try
        while !PO_OUT.finished(out)
            time() < deadline || error("timed out with $(length(got)) bytes received")
            most = max(most, po_queued(out.chunks))
            # At most 64 chunks per pass, then a pause, as an event loop that is busy elsewhere would.
            k = 0
            PO_OUT.feed_chunks!(b -> append!(got, b), out, () -> (k += 1) <= 64)
            sleep(0.001)
        end
    finally
        close(s)
    end
    @test most <= PO_OUT.MAX_QUEUED_CHUNKS
    # The reader filled the queue at least once, so the bound was reached and back-pressure applied.
    @test most == PO_OUT.MAX_QUEUED_CHUNKS
    @test got == po_seq_bytes(n)
    @test PO_OUT.check_error(out) === nothing
    @test process_exited(s.process)
end

@testset "closing while the queue is full returns and leaves no child" begin
    s = PO_PTY.spawn(Cmd(["seq", "1", "200000"]); rows = 24, cols = 80)
    out = PO_OUT.start_reader(s)
    deadline = time() + 60
    # The reader has filled the queue when it is full and stays so: it is then blocked on `put!`.
    while po_queued(out.chunks) < PO_OUT.MAX_QUEUED_CHUNKS
        time() < deadline || error("the queue did not fill")
        sleep(0.01)
    end
    sleep(0.2)
    @test po_queued(out.chunks) == PO_OUT.MAX_QUEUED_CHUNKS

    # As the window does: close the session, then wait for the reader while feeding its output.
    close(s)
    got = UInt8[]
    waiter = @async PO_OUT.wait_reader!(b -> append!(got, b), out)
    @test timedwait(() -> istaskdone(waiter), 30) === :ok
    fetch(waiter)
    @test PO_OUT.finished(out)
    @test PO_OUT.check_error(out) === nothing
    @test process_exited(s.process)
    @test !isopen(s)
    # What was received is an in-order prefix of the output.
    @test !isempty(got)
    @test got == po_seq_bytes(200_000)[1:length(got)]
end

@testset "closing an idle session ends the reader without an error" begin
    s = PO_PTY.spawn(Cmd(["sleep", "100"]); rows = 24, cols = 80)
    out = PO_OUT.start_reader(s)
    sleep(0.1)
    close(s; timeout = 1)
    got = UInt8[]
    waiter = @async PO_OUT.wait_reader!(b -> append!(got, b), out)
    @test timedwait(() -> istaskdone(waiter), 30) === :ok
    fetch(waiter)
    @test isempty(got)
    @test PO_OUT.check_error(out) === nothing
    @test process_exited(s.process)
end

const PO_LL = MPIEnsemble.LineLog
const PO_VT = MPIEnsemble.VTParse

@testset "session_ended recognises the child's end of the pseudo-terminal" begin
    @test PO_OUT.session_ended(Base.IOError("write", Base.UV_EIO))
    @test !PO_OUT.session_ended(Base.IOError("stream is closed or unusable", 0))
    @test !PO_OUT.session_ended(ErrorException("write failed"))
end

@testset "queue_replies! passes replies to the writer and drops them when it cannot write" begin
    term = PO_VT.Terminal(4, 40)
    input = Channel{Vector{UInt8}}(Inf)
    gate = Channel{Nothing}(0)
    writer = @async take!(gate)

    PO_VT.feed!(term, Vector{UInt8}(codeunits("ab\e[6n")), UInt64(1))
    PO_OUT.queue_replies!(input, writer, term)
    @test take!(input) == Vector{UInt8}("\e[1;3R")
    @test isempty(PO_VT.take_replies!(term))

    close(input)
    PO_VT.feed!(term, Vector{UInt8}(codeunits("\e[5n")), UInt64(1))
    PO_OUT.queue_replies!(input, writer, term)
    @test isempty(PO_VT.take_replies!(term))

    put!(gate, nothing)
    wait(writer)
    finished_writer = @async nothing
    wait(finished_writer)
    input = Channel{Vector{UInt8}}(Inf)
    PO_VT.feed!(term, Vector{UInt8}(codeunits("\e[5n")), UInt64(1))
    PO_OUT.queue_replies!(input, finished_writer, term)
    @test !isready(input)
    @test isempty(PO_VT.take_replies!(term))
end

# Runs `script` with `sh -c` in a pseudo-terminal, as the window does: a reader task, the output fed
# to the log with `feed_output!`, and the replies queued with `queue_replies!` for the writer task.
# Fails if the child has not exited within `timeout` seconds, which is how a child that waits for a
# reply that never comes shows up.
function po_run_child(script::AbstractString; timeout::Real = 20)
    s = PO_PTY.spawn(Cmd(["sh", "-c", script]); rows = 24, cols = 80)
    log = PO_LL.RankLog(0)
    term = PO_LL.begin_session!(log, time_ns(), 24, 80)
    input = Channel{Vector{UInt8}}(Inf)
    errors = Ref{Any}(nothing)
    writer = PO_OUT.start_writer(s, input, errors, () -> false)
    out = PO_OUT.start_reader(s)
    feed(bytes) = (PO_LL.feed_output!(log, term, bytes, time_ns()); PO_OUT.queue_replies!(input, writer, term))
    deadline = time() + timeout
    try
        while !PO_OUT.finished(out)
            time() < deadline || error("the child did not exit within $timeout s: $script")
            PO_OUT.feed_chunks!(feed, out)
            sleep(0.002)
        end
    finally
        close(input)
        close(s)
    end
    @test timedwait(() -> istaskdone(writer), 10) === :ok
    @test errors[] === nothing
    @test PO_OUT.check_error(out) === nothing
    @test process_exited(s.process)
    @test s.process.exitcode == 0
    PO_LL.end_session!(log, term, time_ns())
    return nothing
end

@testset "a child that waits for a cursor position report receives it" begin
    dir = mktempdir()
    file = joinpath(dir, "reply")
    # The text before the query moves the cursor to column 4. Raw mode keeps the reply out of the
    # echo, and dd reads exactly the six bytes of the reply.
    po_run_child("stty raw -echo; printf 'abc\\033[6n'; dd bs=1 count=6 of='$file' 2>/dev/null")
    @test read(file) == Vector{UInt8}("\e[1;4R")
end

@testset "a child that waits for a primary device attributes reply receives it" begin
    dir = mktempdir()
    file = joinpath(dir, "reply")
    po_run_child("stty raw -echo; printf '\\033[c'; dd bs=1 count=7 of='$file' 2>/dev/null")
    @test read(file) == Vector{UInt8}("\e[?1;2c")
end
