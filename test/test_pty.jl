const Pty = MPIEnsemble.Pty

# Output from a session, accumulated by a task so that reads never block the test.
mutable struct PtyCapture
    lock::ReentrantLock
    buf::Vector{UInt8}
    task::Task
end

function pty_capture(s::Pty.Session)
    c = PtyCapture(ReentrantLock(), UInt8[], current_task())
    c.task = @async while true
        b = try
            readavailable(s)
        catch
            break
        end
        isempty(b) && break
        lock(() -> append!(c.buf, b), c.lock)
    end
    return c
end

# Received text with terminal escape sequences removed.
function pty_text(c::PtyCapture)
    raw = lock(() -> String(copy(c.buf)), c.lock)
    return replace(raw, r"\e\][^\a\e]*(\a|\e\\)" => "", r"\e\[[0-9;?]*[ -/]*[@-~]" => "")
end

# Wait until the text matches `pat`, returning the text. Throws if the output
# stops before a match or the timeout passes.
function pty_wait(c::PtyCapture, pat; timeout::Real = 30)
    deadline = time() + timeout
    while true
        t = pty_text(c)
        occursin(pat, t) && return t
        istaskdone(c.task) && error("session output ended before $pat; received: $(last(t, 400))")
        time() > deadline && error("timed out waiting for $pat; received: $(last(t, 400))")
        sleep(0.05)
    end
end

julia_child() = Cmd(vcat(Base.julia_cmd().exec, ["-q", "--startup-file=no"]))

# Run `f(session, capture)` in a headless Julia REPL, closing the session afterwards.
function with_julia(f; rows::Integer = 24, cols::Integer = 80)
    s = Pty.spawn(julia_child(); rows, cols)
    c = pty_capture(s)
    try
        pty_wait(c, "julia> ")
        f(s, c)
    finally
        close(s)
    end
end

function mem_available_gib()
    for line in eachline("/proc/meminfo")
        startswith(line, "MemAvailable:") || continue
        return parse(Int, split(line)[2]) / 2^20
    end
    error("MemAvailable not found in /proc/meminfo")
end

fd_count() = length(readdir("/proc/self/fd"))

@testset "Pty" begin
    @testset "evaluate and read result" begin
        with_julia() do s, c
            write(s, "1+1\n")
            pty_wait(c, r"^2\r?$"m)
        end
    end

    @testset "Ctrl+C interrupts and REPL continues" begin
        with_julia() do s, c
            write(s, "sleep(30)\n")
            sleep(2)
            write(s, 0x03)
            pty_wait(c, r"InterruptException[\s\S]*julia> "; timeout = 10)
            write(s, "1+1\n")
            pty_wait(c, r"^2\r?$"m)
        end
    end

    @testset "resize changes the child's displaysize" begin
        with_julia() do s, c
            resize!(s, 40, 100)
            sleep(0.5)
            write(s, "displaysize(stdout)\n")
            pty_wait(c, "(40, 100)")
        end
    end

    @testset "exit status" begin
        s = Pty.spawn(`sh -c "exit 7"`)
        try
            @test Pty.exit_status(s) == 7
        finally
            close(s)
        end
    end

    @testset "close kills a child that ignores Ctrl+D" begin
        s = Pty.spawn(`sh -c "exec sleep 60"`)
        pid = getpid(s.process)
        t0 = time()
        close(s; timeout = 1)
        @test 0.9 < time() - t0 < 10
        @test !ispath("/proc/$pid")
        @test_throws "signal 9" Pty.exit_status(s)
    end

    @testset "errors do not leak descriptors" begin
        warm = Pty.spawn(`sh -c "exit 0"`)
        Pty.exit_status(warm)
        close(warm)
        before = fd_count()
        @test_throws ArgumentError Pty.spawn(`sh -c "exit 0"`; rows = -1)
        @test fd_count() == before
    end

    @testset "no leftover processes after many sessions" begin
        gib = mem_available_gib()
        n = gib > 10 ? 16 : 4
        n < 16 && @info "Pty: $n sessions instead of 16 because MemAvailable is $(round(gib; digits = 1)) GiB (below 10 GiB)"
        sessions = Pty.Session[]
        try
            for _ in 1:n
                push!(sessions, Pty.spawn(julia_child()))
            end
            captures = [pty_capture(s) for s in sessions]
            for c in captures
                pty_wait(c, "julia> "; timeout = 60)
            end
            for (s, c) in zip(sessions, captures)
                write(s, "1+1\n")
                pty_wait(c, r"^2\r?$"m; timeout = 60)
            end
            pids = [getpid(s.process) for s in sessions]
            for s in sessions
                close(s)
            end
            @test all(!isopen(s) for s in sessions)
            @test all(!ispath("/proc/$pid") for pid in pids)
        finally
            foreach(close, sessions)
        end
    end
end

# True once the process has exited, or is a zombie awaiting reaping.
function process_gone(pid::Integer)
    isdir("/proc/$pid") || return true
    stat = try
        read("/proc/$pid/stat", String)
    catch
        return true
    end
    return split(split(stat, ')'; limit = 2)[2])[1] == "Z"
end

environ_has(pid::Integer, entry::AbstractString) = entry in split(read("/proc/$pid/environ", String), '\0')

pty_parent_script = joinpath(@__DIR__, "pty_parent.jl")

# Start pty_parent.jl with the marker `run_id` in its environment, and return the process and the
# pid of the child it reports on its first line of output.
function start_pty_parent(run_id::AbstractString, args...; threads::Integer = 1)
    parent_cmd = Cmd(vcat(Base.julia_cmd().exec, ["--startup-file=no", "-t", string(threads), pty_parent_script], collect(String, args)))
    proc = open(pipeline(addenv(parent_cmd, "MPIENSEMBLE_TEST_RUN" => run_id); stderr = devnull))
    try
        line = @async readline(proc.out)
        timedwait(() -> istaskdone(line), 120; pollint = 0.01) === :timed_out &&
            error("timed out waiting for pty_parent.jl to report the child's pid")
        isempty(fetch(line)) && error("pty_parent.jl exited before reporting the child's pid")
        return proc, parse(Int, fetch(line))
    catch
        process_exited(proc) || kill(proc, Base.SIGKILL)
        wait(proc)
        rethrow()
    end
end

@testset "Pty child has the pid of the command and is its session leader" begin
    s = Pty.spawn(Cmd(["sleep", "30"]))
    try
        pid = getpid(s.process)
        # `spawn` returns once `setsid` has started, so wait for it to exec `sleep`.
        timedwait(() -> read("/proc/$pid/comm", String) == "sleep\n", 5; pollint = 0.01) === :ok ||
            error("the child is $(strip(read("/proc/$pid/comm", String))), not sleep")
        # Fields after the command name: state, parent pid, process group, session.
        fields = split(split(read("/proc/$pid/stat", String), ')'; limit = 2)[2])
        @test parse(Int, fields[2]) == getpid()
        @test parse(Int, fields[4]) == pid
    finally
        close(s; timeout = 1)
    end
end

@testset "Pty spawn fails fast when setpriv is missing" begin
    setsid_path = Sys.which("setsid")
    mktempdir() do dir
        symlink(setsid_path, joinpath(dir, "setsid"))
        withenv("PATH" => dir) do
            @test_throws "need the `setpriv` command" Pty.spawn(Cmd(["sleep", "30"]))
        end
    end
end

@testset "Pty child ends when the process that started it is killed" begin
    # Each trial runs the spawning process as a subprocess and kills it, or lets it exit with an
    # uncaught error, then checks that the child has gone.
    trials = [
        ("julia", "main", "kill"),
        ("julia", "main", "kill"),
        ("julia", "main", "error"),
        ("julia", "thread", "kill"),
        ("sleep", "main", "kill"),
        ("sleep", "main", "kill"),
    ]
    for (i, (child, where, how)) in enumerate(trials)
        run_id = "$(getpid())-$(time_ns())-$i"
        @testset "child $child, spawned from $where, parent $how" begin
            args = how == "error" ? [child, where, "error"] : [child, where]
            proc, pid = start_pty_parent(run_id, args...; threads = where == "thread" ? 2 : 1)
            try
                @test environ_has(pid, "MPIENSEMBLE_TEST_RUN=$run_id")
                if how == "kill"
                    kill(proc, Base.SIGKILL)
                end
                wait(proc)
                @test proc.termsignal == (how == "kill" ? Base.SIGKILL : 0)
                @test how == "kill" || proc.exitcode == 1
                deadline = time() + 5
                while !process_gone(pid) && time() < deadline
                    sleep(0.05)
                end
                @test process_gone(pid)
            finally
                close(proc.out)
                process_exited(proc) || kill(proc, Base.SIGKILL)
                if !process_gone(pid) && environ_has(pid, "MPIENSEMBLE_TEST_RUN=$run_id")
                    kill(pid, Base.SIGKILL)
                end
            end
        end
    end
end

@testset "Ctrl+D and exit() end a Julia child with status 0" begin
    for input in ("\x04", "exit()\n")
        s = Pty.spawn(julia_child())
        c = pty_capture(s)
        try
            pty_wait(c, "julia> "; timeout = 120)
            write(s, input)
            @test Pty.exit_status(s) == 0
        finally
            close(s)
        end
    end
end

@testset "is_raw is false for a cooked terminal and true at the Julia prompt" begin
    s = Pty.spawn(`sleep 30`)
    try
        @test !Pty.is_raw(s)
    finally
        close(s)
    end
    s = Pty.spawn(julia_child())
    c = pty_capture(s)
    try
        pty_wait(c, "julia> "; timeout = 120)
        deadline = time() + 30
        while !Pty.is_raw(s) && time() < deadline
            sleep(0.02)
        end
        @test Pty.is_raw(s)
    finally
        close(s)
    end
end
