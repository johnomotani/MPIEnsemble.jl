# Tests for the per-rank Python wrapper, src/wrapper/wrapper.py. The Python unit tests in test/wrapper
# run under the Python from Python_jll, which the launcher uses too. A round trip from Julia drives
# the wrapper over a Unix socket, with a julia child that is started from the same binary as this
# process.

using Sockets: listen, accept
using MPIEnsemble.MpiLauncher: python_executable, check_python

const WRAPPER_SCRIPT = joinpath(@__DIR__, "..", "src", "wrapper", "wrapper.py")
const WRAPPER_TESTS = joinpath(@__DIR__, "wrapper")
const WRAPPER_DATA, WRAPPER_RESIZE, WRAPPER_SIGNAL, WRAPPER_HELLO, WRAPPER_EXIT = 0x01, 0x02, 0x03, 0x04, 0x05
# Seconds allowed for a whole wrapper session, including the startup of julia.
const WRAPPER_TIMEOUT = 120

# The Python from Python_jll, checked to be 3.11 or later. Fails rather than skipping when it is not.
wrapper_python() = check_python(python_executable())

# The wrapper's environment: no TERM, DISPLAY or MPI rank variables, plus the given socket and PATH.
# With `rank` given, the rank variables describe rank `rank` of one rank.
function wrapper_env(; socket::AbstractString, path::AbstractString, rank::Union{Integer, Nothing})
    env = Dict{String, String}(k => v for (k, v) in ENV
        if !(k in ("TERM", "DISPLAY")) && !any(p -> startswith(k, p), ("OMPI_", "PMIX_", "PMI_")))
    env["PATH"] = path
    env["MPIENSEMBLE_SOCKET"] = socket
    if rank !== nothing
        env["OMPI_COMM_WORLD_RANK"] = string(rank)
        env["OMPI_COMM_WORLD_SIZE"] = "1"
    end
    return env
end

# PATH for children that should find the same julia as this process.
wrapper_path() = Sys.BINDIR * ":" * get(ENV, "PATH", "")

# Start the wrapper with stdout and stderr going to `log`. `args` follow the script path on the command line.
function wrapper_start(python, env, log::IO; args::Vector{String} = String[])
    cmd = setenv(Cmd([python, "-X", "dev", "-W", "error::DeprecationWarning", WRAPPER_SCRIPT, args...]), env)
    return run(pipeline(cmd; stdin = devnull, stdout = log, stderr = log); wait = false)
end

# If the wrapper has not ended after `timeout` seconds, kill it and close `server`, so that a
# blocked accept or read fails instead of hanging the test run.
function wrapper_watchdog(proc, server; timeout = WRAPPER_TIMEOUT)
    return Timer(timeout) do _
        process_running(proc) && kill(proc)
        isopen(server) && close(server)
    end
end

# Frames are a 1-byte type, a 4-byte big-endian length, and the payload.
function wrapper_send(io, type::UInt8, payload::Vector{UInt8} = UInt8[])
    write(io, type)
    write(io, hton(UInt32(length(payload))))
    write(io, payload)
    return nothing
end

function wrapper_read(io)
    type = read(io, UInt8)
    n = Int(ntoh(read(io, UInt32)))
    return type, read(io, n)
end

# A big-endian integer of type `T` at byte `i` of `bytes`.
wrapper_int(::Type{T}, bytes, i) where {T} = ntoh(only(reinterpret(T, bytes[i:(i + sizeof(T) - 1)])))

# Read DATA frames until `marker` (a string, or a regex) matches the output, and return the output so far.
function wrapper_read_output_until(conn, marker)
    output = UInt8[]
    while !occursin(marker, String(copy(output)))
        type, payload = wrapper_read(conn)
        type == WRAPPER_DATA || error("expected a DATA frame, got type $type")
        append!(output, payload)
    end
    return String(output)
end

# Read frames until EXIT, returning the output of the DATA frames and the exit code and signal.
function wrapper_read_until_exit(conn)
    output = UInt8[]
    while true
        type, payload = wrapper_read(conn)
        if type == WRAPPER_EXIT
            return (; output = String(output), code = Int(wrapper_int(Int32, payload, 1)),
                signal = Int(wrapper_int(Int32, payload, 5)))
        elseif type == WRAPPER_DATA
            append!(output, payload)
        else
            error("unexpected frame type $type from the wrapper")
        end
    end
end

# Run the wrapper for one session, with a fresh socket in `dir`. With `command` given, the wrapper runs it, as
# `wrapper.py -- command...`; otherwise it runs the default command. Reads HELLO, which must report rank 0 of
# 1 rank, and sends an initial terminal size of 24 by 80. Then returns `f(conn)`, once the wrapper has ended.
# The result is `(; result, exitcode, termsignal, log)`.
function wrapper_session(f, python, dir::AbstractString; path::AbstractString, command::Vector{String} = String[])
    socket = joinpath(dir, "s")
    @test sizeof(socket) < 100
    server = listen(socket)
    log = joinpath(dir, "wrapper.log")
    env = wrapper_env(; socket, path, rank = 0)
    io = open(log, "w")
    args = isempty(command) ? String[] : ["--", command...]
    proc = wrapper_start(python, env, io; args)
    watchdog = wrapper_watchdog(proc, server)
    try
        conn = accept(server)
        type, hello = wrapper_read(conn)
        type == WRAPPER_HELLO || error("the first frame was type $type, not HELLO")
        @test (wrapper_int(UInt32, hello, 1), wrapper_int(UInt32, hello, 5)) == (0, 1)
        wrapper_send(conn, WRAPPER_RESIZE, UInt8[0, 24, 0, 80])
        result = f(conn)
        wait(proc)
        isopen(io) && close(io)
        return (; result, exitcode = proc.exitcode, termsignal = proc.termsignal, log = read(log, String))
    catch err
        process_running(proc) && kill(proc)
        wait(proc)
        isopen(io) && close(io)
        error("wrapper session failed: ", sprint(showerror, err, catch_backtrace()),
            "\nwrapper log:\n", read(log, String))
    finally
        isopen(io) && close(io)
        close(watchdog)
        isopen(server) && close(server)
    end
end

@testset "Python wrapper" begin
    python = wrapper_python()

    @testset "Python unit tests" begin
        mktempdir() do dir
            log = joinpath(dir, "unittest.log")
            env = wrapper_env(; socket = joinpath(dir, "unused"), path = wrapper_path(), rank = nothing)
            cmd = setenv(Cmd([python, "-B", "-m", "unittest", "discover", "-s", WRAPPER_TESTS]), env)
            proc = open(log, "w") do io
                p = run(pipeline(cmd; stdin = devnull, stdout = io, stderr = io); wait = false)
                watchdog = Timer(WRAPPER_TIMEOUT) do _
                    process_running(p) && kill(p)
                end
                wait(p)
                close(watchdog)
                p
            end
            proc.exitcode == 0 || error("Python unit tests failed:\n", read(log, String))
        end
    end

    @testset "round trip with a julia child" begin
        mktempdir() do dir
            session = wrapper_session(python, dir; path = wrapper_path()) do conn
                wrapper_send(conn, WRAPPER_DATA, Vector{UInt8}(codeunits("println(\"wrapper-marker \", 6 * 7)\n")))
                # Ctrl+D is sent once the prompt is back. Before that, julia is still evaluating, and the
                # byte is not read as end of input.
                wrapper_read_output_until(conn, r"wrapper-marker 42\r\n.*julia> "s)
                wrapper_send(conn, WRAPPER_DATA, UInt8[0x04])  # Ctrl+D at the prompt ends julia
                wrapper_read_until_exit(conn)
            end
            @test session.result.code == 0
            @test session.result.signal == 0
            @test session.exitcode == 0
            @test session.termsignal == 0
            @test isempty(session.log)
        end
    end

    @testset "julia missing from PATH" begin
        mktempdir() do dir
            empty_bin = joinpath(dir, "bin")
            mkdir(empty_bin)
            session = wrapper_session(python, dir; path = empty_bin) do conn
                wrapper_read_until_exit(conn)
            end
            @test session.result.code == 127
            @test session.result.signal == 0
            @test occursin("wrapper: command not found: julia", session.result.output)
            @test session.exitcode == 127
            @test isempty(session.log)
        end
    end

    @testset "command not found" begin
        mktempdir() do dir
            session = wrapper_session(python, dir; path = wrapper_path(),
                command = ["no-such-command-for-tests", "-t2"]) do conn
                wrapper_read_until_exit(conn)
            end
            @test session.result.code == 127
            @test session.result.signal == 0
            @test occursin("wrapper: command not found: no-such-command-for-tests", session.result.output)
            @test session.exitcode == 127
            @test isempty(session.log)
        end
    end

    @testset "command with arguments containing spaces, and TERM" begin
        # `sh` stands in for the command. It prints each argument in brackets, so an argument that was split or
        # merged shows, and the TERM it was given.
        script = "for a in \"\$@\"; do printf '[%s]\\n' \"\$a\"; done; printf 'TERM=%s\\n' \"\$TERM\""
        command = ["sh", "-c", script, "argv", "one two", "-t2", "--project=a b"]
        mktempdir() do dir
            session = wrapper_session(python, dir; path = wrapper_path(), command) do conn
                wrapper_read_until_exit(conn)
            end
            @test session.result.code == 0
            @test session.result.signal == 0
            @test session.exitcode == 0
            for line in ("[one two]", "[-t2]", "[--project=a b]", "TERM=xterm-256color")
                @test occursin(line, session.result.output)
            end
            @test !occursin("[-q]", session.result.output)
            @test isempty(session.log)
        end
    end

    @testset "missing rank variables" begin
        mktempdir() do dir
            log = joinpath(dir, "wrapper.log")
            env = wrapper_env(; socket = joinpath(dir, "s"), path = wrapper_path(), rank = nothing)
            proc = open(log, "w") do io
                p = wrapper_start(python, env, io)
                watchdog = Timer(WRAPPER_TIMEOUT) do _
                    process_running(p) && kill(p)
                end
                wait(p)
                close(watchdog)
                p
            end
            @test proc.exitcode == 1
            text = read(log, String)
            @test occursin("no MPI rank variables are set", text)
            @test !occursin("Traceback", text)
        end
    end
end
