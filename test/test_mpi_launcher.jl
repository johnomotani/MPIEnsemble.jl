# Tests for MpiLauncher. Most tests use a fake launcher (test/mpi/fake_mpiexec.sh), which starts the
# program once per rank, and either a fake wrapper (test/mpi/fake_wrapper.py, no julia) or the real
# wrapper with a julia REPL per rank. Those run wherever sh, setsid and python3 (3.11 or later) exist.
# The testset "real MPI launcher" needs an mpiexec on PATH and is not run otherwise.

using MPIEnsemble.MpiLauncher
using MPIEnsemble.MpiLauncher: MAX_PAYLOAD, T_DATA, T_RESIZE, T_SIGNAL, T_HELLO, T_EXIT, resize_payload,
    parse_hello, mpiexec_from_preference

const FAKE_LAUNCHER = Cmd(["sh", joinpath(@__DIR__, "mpi", "fake_mpiexec.sh")])
const FAKE_WRAPPER = joinpath(@__DIR__, "mpi", "fake_wrapper.py")
# Seconds allowed for ranks with a julia REPL to start and answer.
const REPL_TIMEOUT = 180

# The ranks need XDG_RUNTIME_DIR for their socket. The tests use the session's directory, or the
# temporary directory where there is none.
with_runtime(f) = withenv(f, "XDG_RUNTIME_DIR" => get(ENV, "XDG_RUNTIME_DIR", tempdir()))

# Read DATA frames from `conn` until their text contains `text`, and return the text read. A timeout
# closes the connection with an error, which `take_frame!` throws.
function read_until(conn::RankConnection, text::AbstractString; timeout = REPL_TIMEOUT)
    output = IOBuffer()
    watchdog = Timer(timeout) do _
        isopen(conn.frames) && close(conn.frames, ErrorException("no output containing \"$text\" from rank $(conn.rank) within $timeout s"))
    end
    try
        while !occursin(text, String(take!(copy(output))))
            frame = take_frame!(conn)
            frame.type == T_EXIT && error("rank $(conn.rank) exited before printing \"$text\"")
            frame.type == T_DATA && write(output, frame.payload)
        end
    finally
        close(watchdog)
    end
    return String(take!(output))
end

# Take frames from `conn` until its EXIT frame, and return (code, signal).
function read_exit(conn::RankConnection; timeout = REPL_TIMEOUT)
    watchdog = Timer(timeout) do _
        isopen(conn.frames) && close(conn.frames, ErrorException("rank $(conn.rank) sent no EXIT frame within $timeout s"))
    end
    try
        while true
            frame = take_frame!(conn)
            frame.type == T_EXIT && return exit_status(frame)
        end
    finally
        close(watchdog)
    end
end

# Whether a process with `pid` still exists, as a zombie or not.
process_exists(pid::Integer) = ccall(:kill, Cint, (Cint, Cint), pid, 0) == 0

# Wait until the process with `pid` is gone. Returns whether it is gone.
function wait_gone(pid::Integer; timeout = 10)
    return timedwait(() -> !process_exists(pid), timeout; pollint = 0.05) === :ok
end

@testset "MpiLauncher frames" begin
    @test encode_frame(T_DATA, UInt8[0x61, 0x62]) == UInt8[0x01, 0x00, 0x00, 0x00, 0x02, 0x61, 0x62]
    @test encode_frame(T_SIGNAL, UInt8[0x02]) == UInt8[0x03, 0x00, 0x00, 0x00, 0x01, 0x02]
    @test encode_frame(T_EXIT) == UInt8[0x05, 0x00, 0x00, 0x00, 0x00]

    stream = vcat(encode_frame(T_DATA, collect(codeunits("hello"))), encode_frame(T_EXIT, zeros(UInt8, 8)),
        encode_frame(T_DATA), encode_frame(T_DATA, rand(UInt8, 1000)))

    # All at once.
    frames = decode!(FrameDecoder(), stream)
    @test length(frames) == 4
    @test [f.type for f in frames] == [T_DATA, T_EXIT, T_DATA, T_DATA]
    @test frames[1].payload == collect(codeunits("hello"))
    @test frames[2].payload == zeros(UInt8, 8)
    @test isempty(frames[3].payload)
    @test length(frames[4].payload) == 1000

    # One byte at a time, and in pieces of 7 bytes: the same frames come out.
    for chunk_size in (1, 7)
        decoder = FrameDecoder()
        got = Frame[]
        for i in 1:chunk_size:length(stream)
            append!(got, decode!(decoder, stream[i:min(i + chunk_size - 1, end)]))
        end
        @test [f.type for f in got] == [T_DATA, T_EXIT, T_DATA, T_DATA]
        @test got[1].payload == frames[1].payload
        @test got[4].payload == frames[4].payload
        @test isempty(decoder.buffer)
    end

    # A header with an unknown type or a length over the limit is an error, as soon as it arrives.
    @test_throws "unknown frame type 9" decode!(FrameDecoder(), UInt8[0x09, 0, 0, 0, 0])
    @test_throws "unknown frame type 0" decode!(FrameDecoder(), UInt8[0x00, 0, 0, 0, 0])
    oversized = vcat(UInt8[0x01], reinterpret(UInt8, [hton(UInt32(MAX_PAYLOAD + 1))]))
    @test_throws "over the limit" decode!(FrameDecoder(), oversized)
    @test_throws ArgumentError encode_frame(0x09, UInt8[])
    @test_throws "over the limit" encode_frame(T_DATA, zeros(UInt8, MAX_PAYLOAD + 1))

    @test resize_payload(24, 80) == UInt8[0x00, 0x18, 0x00, 0x50]
    @test_throws "rows must be from 1" resize_payload(0, 80)
    @test_throws "columns must be from 1" resize_payload(24, 70000)

    @test parse_hello(reinterpret(UInt8, [hton(UInt32(1)), hton(UInt32(4)), hton(UInt32(99))])) == (1, 4, 99)
    @test_throws "HELLO payload must be 12 bytes" parse_hello(UInt8[1, 2, 3])

    @test exit_status(Frame(T_EXIT, reinterpret(UInt8, [hton(Int32(-1)), hton(Int32(0))]))) == (-1, 0)
    @test exit_status(Frame(T_EXIT, reinterpret(UInt8, [hton(Int32(0)), hton(Int32(9))]))) == (0, 9)
    @test_throws "EXIT payload must be 8 bytes" exit_status(Frame(T_EXIT, UInt8[0]))
    @test_throws ArgumentError exit_status(Frame(T_DATA, UInt8[]))
end

@testset "MpiLauncher launcher command" begin
    @test mpiexec_from_preference("mpiexec").exec == ["mpiexec"]
    @test mpiexec_from_preference(["/usr/bin/mpiexec", "--bind-to", "none"]).exec ==
        ["/usr/bin/mpiexec", "--bind-to", "none"]
    @test_throws "mpiexec preference is not set" mpiexec_from_preference(nothing)
    @test_throws "empty list" mpiexec_from_preference(String[])
    @test_throws "neither \"system\" nor a JLL" mpiexec_command("OpenMPI")
    # A JLL that is not a dependency of the active project is an error, not a guessed path.
    @test_throws "is not a dependency of the active project" mpiexec_command("NoSuchMPI_jll")
end

@testset "MpiLauncher argument and environment errors" begin
    @test_throws ArgumentError launch(0, 24, 80; launcher = FAKE_LAUNCHER)
    @test_throws ArgumentError launch(1, 0, 80; launcher = FAKE_LAUNCHER)
    @test_throws ArgumentError launch(1, 24, 80; launcher = FAKE_LAUNCHER, timeout = 0)
    @test_throws "was not found" launch(1, 24, 80; launcher = Cmd(["/nonexistent/mpiexec"]))
    no_launch() = launch(1, 24, 80; launcher = FAKE_LAUNCHER)
    @test_throws "python3 is not on PATH" withenv(no_launch, "PATH" => "")
    @test_throws "XDG_RUNTIME_DIR is not set" withenv(no_launch, "XDG_RUNTIME_DIR" => nothing)
    long = joinpath(tempdir(), "x"^70)
    mkpath(long)
    try
        @test_throws "must be shorter than 100" withenv(no_launch, "XDG_RUNTIME_DIR" => long)
    finally
        rm(long; recursive = true, force = true)
    end
end

@testset "MpiLauncher with a fake launcher and fake wrappers" begin
    with_runtime() do
        @testset "launcher exits before the ranks connect" begin
            @test_throws "exited before all 2 ranks connected" launch(2, 24, 80;
                launcher = Cmd(["sh", "-c", "exit 3"]), timeout = 30, wrapper = FAKE_WRAPPER)
        end

        @testset "ranks do not connect in time" begin
            withenv("FAKE_WRAPPER_MODE" => "silent") do
                @test_throws "only 0 of 2 ranks connected within 1 s" launch(2, 24, 80;
                    launcher = FAKE_LAUNCHER, timeout = 1, wrapper = FAKE_WRAPPER)
            end
        end

        @testset "HELLO with the wrong size" begin
            withenv("FAKE_WRAPPER_MODE" => "wrong_size") do
                @test_throws "reports a job of 3 ranks, but 2 were launched" launch(2, 24, 80;
                    launcher = FAKE_LAUNCHER, timeout = 30, wrapper = FAKE_WRAPPER)
            end
        end

        @testset "echo: frames both ways" begin
            withenv("FAKE_WRAPPER_MODE" => "echo") do
                job = launch(2, 24, 80; launcher = FAKE_LAUNCHER, timeout = 30, wrapper = FAKE_WRAPPER)
                try
                    @test [conn.rank for conn in job.ranks] == [0, 1]
                    @test all(conn -> conn.pid > 0, job.ranks)
                    c0, c1 = job.ranks
                    @test read_until(c0, "resize 24 80") == "resize 24 80\n"
                    @test read_until(c1, "resize 24 80") == "resize 24 80\n"
                    send_input!(c0, Vector{UInt8}(codeunits("abc")))
                    @test read_until(c0, "abc") == "abc"
                    send_resize!(c1, 30, 100)
                    @test read_until(c1, "resize 30 100") == "resize 30 100\n"
                    send_interrupt!(c0)
                    @test read_until(c0, "signal 2") == "signal 2\n"
                finally
                    shutdown!(job; exit_timeout = 10)
                end
                @test !isdir(job.directory)
                @test process_exited(job.process)
            end
        end

        @testset "EXIT frame is delivered" begin
            withenv("FAKE_WRAPPER_MODE" => "exit_frame") do
                job = launch(1, 24, 80; launcher = FAKE_LAUNCHER, timeout = 30, wrapper = FAKE_WRAPPER)
                try
                    conn = job.ranks[1]
                    @test read_until(conn, "bye") == "bye\n"
                    @test read_exit(conn) == (7, 0)
                finally
                    shutdown!(job; exit_timeout = 10)
                end
            end
        end

        @testset "socket closed without EXIT is an error" begin
            withenv("FAKE_WRAPPER_MODE" => "no_exit") do
                job = launch(1, 24, 80; launcher = FAKE_LAUNCHER, timeout = 30, wrapper = FAKE_WRAPPER)
                try
                    conn = job.ranks[1]
                    @test read_until(conn, "bye") == "bye\n"
                    err = try
                        take_frame!(conn)
                        nothing
                    catch e
                        e
                    end
                    @test err isa ErrorException
                    @test occursin("without an EXIT frame", err.msg)
                finally
                    shutdown!(job; exit_timeout = 10)
                end
            end
        end

        @testset "shutdown kills a launcher that does not exit" begin
            withenv("FAKE_WRAPPER_MODE" => "ignore_close") do
                job = launch(2, 24, 80; launcher = FAKE_LAUNCHER, timeout = 30, wrapper = FAKE_WRAPPER)
                pids = [conn.pid for conn in job.ranks]
                @test all(process_exists, pids)
                @test_logs (:warn, r"did not exit") shutdown!(job; exit_timeout = 1)
                @test process_exited(job.process)
                @test all(wait_gone, pids)
                @test !isdir(job.directory)
            end
        end
    end
end

@testset "MpiLauncher with the real wrapper and julia, using the fake launcher" begin
    with_runtime() do
        job = launch(2, 24, 80; launcher = FAKE_LAUNCHER, timeout = REPL_TIMEOUT)
        try
            for conn in job.ranks
                send_input!(conn, Vector{UInt8}(codeunits("println(\"hello from \", ENV[\"OMPI_COMM_WORLD_RANK\"])\r")))
            end
            for conn in job.ranks
                @test occursin("hello from $(conn.rank)", read_until(conn, "hello from $(conn.rank)"))
            end
            for conn in job.ranks
                send_input!(conn, Vector{UInt8}(codeunits("exit()\r")))
                @test read_exit(conn) == (0, 0)
            end
        finally
            shutdown!(job)
        end
        @test process_exited(job.process)
        @test !isdir(job.directory)
    end
end

const REAL_MPIEXEC = Sys.which("mpiexec")
if REAL_MPIEXEC === nothing
    @info "no mpiexec on PATH: the MpiLauncher tests with a real MPI launcher were not run"
else
    @testset "MpiLauncher with a real MPI launcher" begin
        with_runtime() do
            job = launch(2, 24, 80; launcher = Cmd([REAL_MPIEXEC]), timeout = REPL_TIMEOUT)
            try
                for conn in job.ranks
                    send_input!(conn, Vector{UInt8}(codeunits("println(\"hello from \", ENV[\"OMPI_COMM_WORLD_RANK\"])\r")))
                end
                for conn in job.ranks
                    @test occursin("hello from $(conn.rank)", read_until(conn, "hello from $(conn.rank)"))
                end
                for conn in job.ranks
                    send_input!(conn, Vector{UInt8}(codeunits("exit()\r")))
                    @test read_exit(conn) == (0, 0)
                end
            finally
                shutdown!(job)
            end
            @test process_exited(job.process)
        end
    end
end
