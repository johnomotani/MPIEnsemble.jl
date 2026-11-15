# Starts one wrapper process per MPI rank under the MPI launcher and connects to each over a Unix
# socket. The frame format is the one documented in src/wrapper/wrapper.py, and it is encoded and
# decoded only in this file. Nothing here uses QML, so the launcher runs without a display.
module MpiLauncher

import MPIPreferences
using Sockets: listen, accept

export Frame, Job, RankConnection, FrameDecoder, encode_frame, decode!, launch, shutdown!, kill!,
    take_frame!, is_closing, send_input!, send_resize!, send_interrupt!, exit_status, mpiexec_command, python_executable

const T_DATA = 0x01
const T_RESIZE = 0x02
const T_SIGNAL = 0x03
const T_HELLO = 0x04
const T_EXIT = 0x05
const KNOWN_TYPES = (T_DATA, T_RESIZE, T_SIGNAL, T_HELLO, T_EXIT)

const SIG_INTERRUPT = 0x02
const FRAME_HEADER_LENGTH = 5
const MAX_PAYLOAD = 1 << 24
const HELLO_LENGTH = 12
const EXIT_LENGTH = 8

# The socket path must be shorter than this many bytes, as the wrapper's socket address holds about 100.
const SOCKET_PATH_LIMIT = 100
const SOCKET_NAME = "ranks.sock"
const MIN_PYTHON = (3, 11)
const WRAPPER_SCRIPT = joinpath(@__DIR__, "wrapper", "wrapper.py")
const RANK_TERM = "xterm-256color"
const RANK_FRAME_BUFFER = 256

# The JLL binaries of MPIPreferences that provide mpiexec on Linux. MicrosoftMPI_jll is Windows only.
const JLL_BINARIES = ("MPICH_jll", "OpenMPI_jll", "MPItrampoline_jll", "MPIABI_jll")

# errno values on Linux.
const ESRCH = 3

"""
    Frame(type, payload)

One message between the parent and a wrapper. `type` is one of the frame types `T_DATA`, `T_RESIZE`,
`T_SIGNAL`, `T_HELLO` and `T_EXIT`, and `payload` holds its bytes.
"""
struct Frame
    type::UInt8
    payload::Vector{UInt8}
end

function check_type(type::Integer)
    type in KNOWN_TYPES || throw(ArgumentError("unknown frame type $type"))
    return nothing
end

"""
    encode_frame(type, payload = UInt8[]) -> Vector{UInt8}

The bytes of one frame: the type as one byte, the length of the payload as a 4-byte big-endian integer,
and then the payload. Throws `ArgumentError` for an unknown type or a payload longer than `MAX_PAYLOAD`.
"""
function encode_frame(type::Integer, payload::AbstractVector{UInt8} = UInt8[])
    check_type(type)
    n = length(payload)
    n <= MAX_PAYLOAD || throw(ArgumentError("payload of $n bytes is over the limit of $MAX_PAYLOAD"))
    io = IOBuffer()
    write(io, UInt8(type), hton(UInt32(n)), payload)
    return take!(io)
end

"""
    FrameDecoder()

Splits a byte stream into frames. Pass each chunk of bytes to `decode!`, which returns the frames that the
bytes complete. A frame may be split across any number of chunks.
"""
mutable struct FrameDecoder
    buffer::Vector{UInt8}
end

FrameDecoder() = FrameDecoder(UInt8[])

"""
    decode!(decoder, bytes) -> Vector{Frame}

Append `bytes` to the stream and return the complete frames it now holds, in order. Throws an error when a
frame header has an unknown type or a length over `MAX_PAYLOAD`. The header is checked as soon as it has
arrived, so a bad length is reported without waiting for the payload.
"""
function decode!(decoder::FrameDecoder, bytes::AbstractVector{UInt8})
    buffer = decoder.buffer
    append!(buffer, bytes)
    frames = Frame[]
    pos = 1
    while length(buffer) - pos + 1 >= FRAME_HEADER_LENGTH
        type = buffer[pos]
        type in KNOWN_TYPES || error("unknown frame type $type")
        n = (Int(buffer[pos + 1]) << 24) | (Int(buffer[pos + 2]) << 16) |
            (Int(buffer[pos + 3]) << 8) | Int(buffer[pos + 4])
        n <= MAX_PAYLOAD || error("frame of type $type has a payload of $n bytes, over the limit of $MAX_PAYLOAD")
        last = pos + FRAME_HEADER_LENGTH + n - 1
        last <= length(buffer) || break
        push!(frames, Frame(type, buffer[(pos + FRAME_HEADER_LENGTH):last]))
        pos = last + 1
    end
    deleteat!(buffer, 1:(pos - 1))
    return frames
end

"""
    resize_payload(rows, cols) -> Vector{UInt8}

The payload of a RESIZE frame: the rows, then the columns, as unsigned 16-bit big-endian integers. Both must
be from 1 to 65535.
"""
function resize_payload(rows::Integer, cols::Integer)
    for (name, value) in (("rows", rows), ("columns", cols))
        1 <= value <= typemax(UInt16) || throw(ArgumentError("$name must be from 1 to $(typemax(UInt16)), got $value"))
    end
    io = IOBuffer()
    write(io, hton(UInt16(rows)), hton(UInt16(cols)))
    return take!(io)
end

"""
    parse_hello(payload) -> (rank, size, pid)

Read the payload of a HELLO frame: the rank, the number of ranks and the process id of the wrapper, as
unsigned 32-bit big-endian integers.
"""
function parse_hello(payload::AbstractVector{UInt8})
    length(payload) == HELLO_LENGTH || error("HELLO payload must be $HELLO_LENGTH bytes, got $(length(payload))")
    io = IOBuffer(payload)
    rank = Int(ntoh(read(io, UInt32)))
    size = Int(ntoh(read(io, UInt32)))
    pid = Int(ntoh(read(io, UInt32)))
    return (rank, size, pid)
end

"""
    exit_status(frame) -> (code, signal)

Read the payload of an EXIT frame: the exit code, then the terminating signal, as signed 32-bit big-endian
integers. The signal is 0 unless julia was killed by a signal, in which case the code is 0.
"""
function exit_status(frame::Frame)
    frame.type == T_EXIT || throw(ArgumentError("frame of type $(frame.type) is not an EXIT frame"))
    length(frame.payload) == EXIT_LENGTH || error("EXIT payload must be $EXIT_LENGTH bytes, got $(length(frame.payload))")
    io = IOBuffer(frame.payload)
    code = Int(ntoh(read(io, Int32)))
    signal = Int(ntoh(read(io, Int32)))
    return (code, signal)
end

"""
    mpiexec_from_preference(value) -> Cmd

The launcher given by the `mpiexec` preference of the system MPI, which is a command name or path, or a
list of its words (MPIPreferences stores a `Cmd` as a list). Throws when the preference is not set.
"""
function mpiexec_from_preference(value)
    value === nothing && error("the mpiexec preference is not set for the system MPI; set it with " *
        "MPIPreferences.use_system_binary(mpiexec = ...)")
    words = value isa AbstractString ? [String(value)] : String.(collect(value))
    isempty(words) && error("the mpiexec preference is an empty list")
    return Cmd(words)
end

"""
    mpiexec_command(binary = MPIPreferences.binary) -> Cmd

The MPI launcher for `binary`, which is the value of `MPIPreferences.binary`.

For `"system"`, the launcher is the `mpiexec` preference. For a JLL binary, the launcher is the `mpiexec()` of
that JLL, which is one of `JLL_BINARIES`. The JLL is a dependency of this package, so it is loaded from the
package's own manifest, whatever the active project is. Any other value throws an error.
"""
function mpiexec_command(binary::AbstractString = MPIPreferences.binary)
    binary == "system" && return system_mpiexec()
    binary in JLL_BINARIES || error("MPIPreferences.binary is \"$binary\", which is neither \"system\" nor " *
        "a JLL binary supported on Linux (" * join(JLL_BINARIES, ", ") * ")")
    return jll_mpiexec(binary)
end

function system_mpiexec()
    isdefined(MPIPreferences, :System) || error("MPIPreferences.binary is \"system\", but MPIPreferences " *
        "did not load its system settings; restart Julia after changing the preferences")
    system = getfield(MPIPreferences, :System)
    return mpiexec_from_preference(getfield(system, :mpiexec_path))
end

# Load the named JLL, which is a dependency of MPIEnsemble, and return its mpiexec().
function jll_mpiexec(name::AbstractString)
    pkgid = Base.identify_package(parentmodule(@__MODULE__), name)
    pkgid === nothing && error("$name is not in the manifest of MPIEnsemble, so its mpiexec cannot be found; " *
        "resolve the package environment that loads MPIEnsemble")
    jll = try
        Base.require(pkgid)
    catch e
        error("cannot load $name for its mpiexec: " * sprint(showerror, e))
    end
    isdefined(jll, :mpiexec) || error("$name does not provide mpiexec for MPIPreferences.binary = " *
        "\"$(MPIPreferences.binary)\"; a JLL provides its MPI only when MPIPreferences.binary names it, so set " *
        "MPIPreferences.binary to \"$name\" to use it")
    cmd = Base.invokelatest(getfield(jll, :mpiexec))
    cmd isa Cmd || error("$name.mpiexec() returned a $(typeof(cmd)), not a Cmd")
    return cmd
end

# Fails unless the launcher's program exists and can be run.
function check_launcher(launcher::Cmd)
    program = first(launcher.exec)
    found = occursin('/', program) ? (isfile(program) && Sys.isexecutable(program)) : Sys.which(program) !== nothing
    found || error("the MPI launcher \"$program\" was not found or is not executable")
    return nothing
end

"""
    python_executable() -> String

The path of the Python interpreter from Python_jll, which runs wrapper.py in each rank. It is the program of
the command that `Python_jll.python()` returns. That command also sets LD_LIBRARY_PATH, which the interpreter
does not need, as it finds its library from its own location; so only the program is used.

Python_jll is loaded by the first call. Its initialisation sets PYTHONHOME in the process environment, which
is restored afterwards, so the julia and MPI processes started later do not inherit it.

Throws an error if Python_jll is not in the manifest of MPIEnsemble or its executable is missing.
"""
function python_executable()
    jll = load_python_jll()
    python = Base.invokelatest(getfield(jll, :python))
    return String(first(python.exec))
end

# Load Python_jll, a dependency of MPIEnsemble, and undo the changes its initialisation makes to ENV.
function load_python_jll()
    pkgid = Base.identify_package(parentmodule(@__MODULE__), "Python_jll")
    pkgid === nothing && error("Python_jll is not in the manifest of MPIEnsemble, so its Python cannot be " *
        "found; resolve the package environment that loads MPIEnsemble")
    before = Dict(ENV)
    try
        return Base.require(pkgid)
    finally
        restore_environment!(before)
    end
end

# Make ENV hold exactly the entries of `before`.
function restore_environment!(before::Dict{String, String})
    for key in collect(keys(ENV))
        haskey(before, key) || delete!(ENV, key)
    end
    for (key, value) in before
        get(ENV, key, nothing) == value || (ENV[key] = value)
    end
    return nothing
end

# Checks that `python` is an executable that runs Python 3.11 or later, and returns it. The check runs the
# interpreter that the ranks will run.
function check_python(python::AbstractString)
    (isfile(python) && Sys.isexecutable(python)) ||
        error("the Python interpreter \"$python\" was not found or is not executable")
    parts = split(readchomp(`$python -c "import sys; print(sys.version_info[0], sys.version_info[1])"`))
    version = parse.(Int, parts)
    (version[1], version[2]) >= MIN_PYTHON || error("wrapper.py needs Python $(join(MIN_PYTHON, ".")) or " *
        "later, but \"$python\" is Python $(join(version, "."))")
    return String(python)
end

# A new directory for the socket, made under XDG_RUNTIME_DIR, and the socket path in it.
function socket_directory()
    runtime = get(ENV, "XDG_RUNTIME_DIR", "")
    isempty(runtime) && error("XDG_RUNTIME_DIR is not set, so there is no directory for the MPI socket; " *
        "it is set by a login session")
    isdir(runtime) || error("XDG_RUNTIME_DIR is \"$runtime\", which is not a directory")
    directory = mktempdir(runtime; prefix = "mpiensemble-", cleanup = false)
    path = joinpath(directory, SOCKET_NAME)
    if ncodeunits(path) >= SOCKET_PATH_LIMIT
        rm(directory; recursive = true, force = true)
        error("the socket path \"$path\" is $(ncodeunits(path)) bytes, but must be shorter than $SOCKET_PATH_LIMIT; " *
            "use a shorter XDG_RUNTIME_DIR")
    end
    return directory, path
end

# The PATH of the ranks. The default command runs the julia of this process, so the directory of that julia
# comes first. An explicit command is run through the PATH of this process as it is.
function rank_path(command::AbstractVector{<:AbstractString})
    existing = get(ENV, "PATH", "")
    isempty(command) || return existing
    julia = joinpath(Sys.BINDIR, "julia")
    isfile(julia) || error("julia was not found at $julia, which the MPI ranks need to run")
    return isempty(existing) ? Sys.BINDIR : Sys.BINDIR * ":" * existing
end

"""
    RankConnection

The connection to one rank's wrapper. `rank` and `pid` come from the wrapper's HELLO frame. Its DATA and
EXIT frames are read with `take_frame!`, and its input is written with `send_input!`, `send_resize!` and
`send_interrupt!`.
"""
mutable struct RankConnection
    const rank::Int
    const pid::Int
    const socket::IO
    const frames::Channel{Frame}
    const write_lock::ReentrantLock
    closing::Bool
end

"""
    Job

The running launcher and its connections. `ranks` holds one `RankConnection` per rank, in rank order.
`process` is the launcher, and `directory` holds the socket, which is removed by `shutdown!`.
"""
struct Job
    ranks::Vector{RankConnection}
    process::Base.Process
    directory::String
end

"""
    take_frame!(conn) -> Frame

Wait for the next DATA or EXIT frame from the rank. Throws the error that ended the connection if the
wrapper's socket closed without an EXIT frame. After an EXIT frame has been taken, or once the connection is
closing (see `is_closing`) and its frames are used up, the connection gives no more frames, and this throws
an `InvalidStateException`.
"""
take_frame!(conn::RankConnection) = take!(conn.frames)

"""
    is_closing(conn) -> Bool

Whether the connection was closed by the launcher, by `shutdown!` or `kill!`. The socket's end of stream is
then expected, and it is not an error.
"""
is_closing(conn::RankConnection) = conn.closing

function send_frame!(conn::RankConnection, type::UInt8, payload::AbstractVector{UInt8})
    bytes = encode_frame(type, payload)
    lock(conn.write_lock) do
        write(conn.socket, bytes)
    end
    return nothing
end

"""
    send_input!(conn, bytes)

Send `bytes` to the rank's terminal as DATA frames, split into frames of at most `MAX_PAYLOAD` bytes.
"""
function send_input!(conn::RankConnection, bytes::AbstractVector{UInt8})
    for range in Iterators.partition(eachindex(bytes), MAX_PAYLOAD)
        send_frame!(conn, T_DATA, bytes[range])
    end
    return nothing
end

"""
    send_resize!(conn, rows, cols)

Set the size of the rank's terminal, in characters.
"""
send_resize!(conn::RankConnection, rows::Integer, cols::Integer) =
    send_frame!(conn, T_RESIZE, resize_payload(rows, cols))

"""
    send_interrupt!(conn)

Send an interrupt (SIGINT) to the rank's julia, as Ctrl+C in its terminal.
"""
send_interrupt!(conn::RankConnection) = send_frame!(conn, T_SIGNAL, UInt8[SIG_INTERRUPT])

# Stop the launcher and everything in its process group. Its process group is its own, from `setsid`.
function kill_process_group!(process::Base.Process)
    if !process_exited(process)
        pgid = getpid(process)
        ret = ccall(:kill, Cint, (Cint, Cint), -pgid, Cint(9))
        if ret != 0
            errno = Base.Libc.errno()
            errno == ESRCH || error("cannot kill process group $pgid: " * Base.Libc.strerror(errno))
        end
    end
    wait(process)
    return nothing
end

# Describes how the launcher ended, for error messages.
function describe_process(process::Base.Process)
    process.termsignal == 0 && return "status $(process.exitcode)"
    return "signal $(process.termsignal)"
end

# Accept connections on `server` and send each to `events` as (:connection, socket), until the server closes.
function accept_connections(server, events::Channel)
    try
        while true
            socket = accept(server)
            put!(events, (:connection, socket))
        end
    catch e
        isopen(server) && isopen(events) && put!(events, (:failure, e))
    end
    return nothing
end

# Read the HELLO frame of one connection and send (:hello, socket, rank, size, pid, decoder) to `events`.
# The decoder is returned with the socket, so that the rank's reader continues from the same stream.
function read_hello(socket::IO, events::Channel)
    decoder = FrameDecoder()
    try
        while true
            bytes = readavailable(socket)
            isempty(bytes) && error("a wrapper closed its connection before sending HELLO")
            frames = decode!(decoder, bytes)
            isempty(frames) && continue
            if length(frames) != 1 || frames[1].type != T_HELLO
                error("the first frame from a wrapper must be HELLO, and HELLO must be the only frame before RESIZE")
            end
            rank, size, pid = parse_hello(frames[1].payload)
            put!(events, (:hello, socket, rank, size, pid, decoder))
            return nothing
        end
    catch e
        isopen(events) && put!(events, (:failure, e))
    end
    return nothing
end

# Read the frames of one rank into its channel until its EXIT frame. Closing the socket without an EXIT
# frame closes the channel with an error, which `take_frame!` throws, unless the connection is closing, in
# which case the channel is closed without an error.
function read_frames(conn::RankConnection, decoder::FrameDecoder)
    try
        while true
            bytes = readavailable(conn.socket)
            if isempty(bytes)
                conn.closing || close(conn.frames, ErrorException("the wrapper for rank $(conn.rank) " *
                    "(pid $(conn.pid)) closed its socket without an EXIT frame"))
                isopen(conn.frames) && close(conn.frames)
                return nothing
            end
            for frame in decode!(decoder, bytes)
                frame.type in (T_DATA, T_EXIT) ||
                    error("unexpected frame of type $(frame.type) from the wrapper for rank $(conn.rank)")
                frame.type == T_EXIT && exit_status(frame)
                put!(conn.frames, frame)
                if frame.type == T_EXIT
                    close(conn.frames)
                    return nothing
                end
            end
        end
    catch e
        # Reading a socket that the launcher closed fails; that ends the reader without an error. Any other
        # failure is passed on.
        if conn.closing
            isopen(conn.frames) && close(conn.frames)
        elseif isopen(conn.frames)
            close(conn.frames, e)
        end
    end
    return nothing
end

# Wait for `nranks` HELLO frames on `server`, while `process` runs. Returns the connections in rank order.
# Every socket accepted is closed if this fails.
function connect_ranks(server, process::Base.Process, nranks::Integer, timeout::Real, resize::Vector{UInt8})
    events = Channel{Any}(Inf)
    accepted = IO[]
    hellos = Dict{Int, Tuple{IO, Int, FrameDecoder}}()
    accepter = @async accept_connections(server, events)
    exit_watch = @async begin
        wait(process)
        isopen(events) && put!(events, (:exited, nothing))
    end
    timer = Timer(timeout) do _
        isopen(events) && put!(events, (:timeout, nothing))
    end
    try
        while length(hellos) < nranks
            event = take!(events)
            kind = event[1]
            if kind === :connection
                push!(accepted, event[2])
                @async read_hello(event[2], events)
            elseif kind === :hello
                _, socket, rank, size, pid, decoder = event
                size == nranks || error("rank $rank reports a job of $size ranks, but $nranks were launched")
                0 <= rank < nranks || error("a wrapper reports rank $rank, outside 0 to $(nranks - 1)")
                haskey(hellos, rank) && error("two wrappers report rank $rank")
                hellos[rank] = (socket, pid, decoder)
            elseif kind === :exited
                error("mpiexec ($(describe_process(process))) exited before all $nranks ranks connected; " *
                    "$(length(hellos)) connected")
            elseif kind === :timeout
                error("only $(length(hellos)) of $nranks ranks connected within $timeout s")
            else
                throw(event[2])
            end
        end
    catch
        for socket in accepted
            isopen(socket) && close(socket)
        end
        rethrow()
    finally
        close(timer)
        close(server)
        close(events)
    end
    connections = RankConnection[]
    for rank in 0:(nranks - 1)
        socket, pid, decoder = hellos[rank]
        conn = RankConnection(rank, pid, socket, Channel{Frame}(RANK_FRAME_BUFFER), ReentrantLock(), false)
        send_frame!(conn, T_RESIZE, resize)
        @async read_frames(conn, decoder)
        push!(connections, conn)
    end
    return connections
end

"""
    kill!(job)

Stop the job at once, without waiting for its ranks to exit. The launcher's process group is killed with
SIGKILL, which stops the launcher and the wrappers, and every process that stayed in that group. Each
connection is marked as closing first, so its reader ends without an error. Output already received is still
returned by `take_frame!`. The socket directory is removed. Calling this on a job whose launcher has already
exited only closes the connections and removes the directory.
"""
function kill!(job::Job)
    for conn in job.ranks
        conn.closing = true
    end
    kill_process_group!(job.process)
    for conn in job.ranks
        isopen(conn.socket) && close(conn.socket)
    end
    rm(job.directory; recursive = true, force = true)
    return nothing
end

"""
    launch(nranks, rows, cols; launcher = mpiexec_command(), python = python_executable(),
        timeout = 60, wrapper = WRAPPER_SCRIPT, command = String[]) -> Job

Start `nranks` wrappers under `launcher`, as `launcher -n nranks python wrapper [-- command...]`, and return once
all of them have connected and been sent the initial terminal size of `rows` by `cols` characters.

`launcher` is a command, such as `mpiexec_command()`. `python` is the path of a Python 3.11 or later
interpreter, by default the one from Python_jll. The launcher, the wrappers and their child processes run in
a new session, so that `shutdown!` can stop all of them. Each child process is `command`, which is a vector of
arguments with the executable first, run as given. It is looked up on the PATH of this process, and receives
TERM=xterm-256color. An empty `command`, the default, runs `julia -q` from the directory of the julia running
this process: that directory comes first on the ranks' PATH. Every rank gets `JULIA_PROJECT` from the active
project. `timeout` is the number of seconds allowed for all the ranks to connect.

Throws an error, after stopping the launcher, if the launcher is not found, exits before all ranks connect,
a wrapper sends a HELLO with the wrong number of ranks or an invalid rank, or the ranks do not all connect
within `timeout` seconds. Also throws if `python` is not an executable or is older than 3.11, or if
XDG_RUNTIME_DIR is unset or leads to a socket path of 100 bytes or more.
"""
function launch(nranks::Integer, rows::Integer, cols::Integer; launcher::Cmd = mpiexec_command(),
        python::AbstractString = python_executable(), timeout::Real = 60, wrapper::AbstractString = WRAPPER_SCRIPT,
        command::AbstractVector{<:AbstractString} = String[])
    nranks >= 1 || throw(ArgumentError("the number of ranks must be at least 1, got $nranks"))
    timeout > 0 || throw(ArgumentError("the timeout must be positive, got $timeout"))
    resize = resize_payload(rows, cols)
    python = check_python(python)
    check_launcher(launcher)
    setsid = Sys.which("setsid")
    setsid === nothing && error("setsid is not on PATH; it starts the MPI launcher in its own session")
    directory, socket_path = socket_directory()
    server = listen(socket_path)
    process = nothing
    try
        environment = Pair{String, String}["MPIENSEMBLE_SOCKET" => socket_path, "PATH" => rank_path(command),
            "TERM" => RANK_TERM]
        project = Base.active_project()
        project === nothing || push!(environment, "JULIA_PROJECT" => project)
        argv = [setsid; launcher.exec; "-n"; string(nranks); python; String(wrapper)]
        # The command follows "--", so that the wrapper reads it whatever its arguments are.
        if !isempty(command)
            push!(argv, "--")
            append!(argv, String.(command))
        end
        cmd = Cmd(argv)
        launcher.env === nothing || (cmd = setenv(cmd, launcher.env))
        cmd = addenv(cmd, environment...)
        process = run(pipeline(cmd; stdin = devnull); wait = false)
        ranks = connect_ranks(server, process, nranks, timeout, resize)
        return Job(ranks, process, directory)
    catch
        close(server)
        process === nothing || kill_process_group!(process)
        rm(directory; recursive = true, force = true)
        rethrow()
    end
end

"""
    shutdown!(job; exit_timeout = 15)

Close every rank's connection, which makes each wrapper stop its julia, then wait up to `exit_timeout` seconds
for the launcher to exit. If it has not, the launcher's process group is killed with SIGKILL and a warning
is logged. Afterwards the socket directory is removed.
"""
function shutdown!(job::Job; exit_timeout::Real = 15)
    for conn in job.ranks
        conn.closing = true
        isopen(conn.socket) && close(conn.socket)
    end
    if timedwait(() -> process_exited(job.process), exit_timeout; pollint = 0.05) === :timed_out
        @warn "mpiexec did not exit $exit_timeout s after its connections closed; killing its process group"
    end
    kill_process_group!(job.process)
    rm(job.directory; recursive = true, force = true)
    return nothing
end

end # module MpiLauncher
