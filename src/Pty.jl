# Pseudo-terminal sessions for running an interactive program (such as the Julia REPL).
# Linux only: the open flags, ioctl request and window-size layout below are Linux values.
module Pty

const O_RDWR = 0x0002
const O_NOCTTY = 0x0100
const O_NONBLOCK = 0x0800
const O_CLOEXEC = 0o2000000
const F_GETFL = 3
const F_SETFL = 4
const TIOCSWINSZ = 0x5414

# Local-mode flags of Linux `struct termios` (octal) and the byte offset of its `c_lflag` field,
# which follows the four-byte `c_iflag`, `c_oflag` and `c_cflag` fields.
const ICANON = 0o000002
const ECHO = 0o000010
const TERMIOS_LFLAG_OFFSET = 12
const TERMIOS_BYTES = 64

const CTRL_D = 0x04

# Layout of Linux `struct winsize`.
struct Winsize
    rows::UInt16
    cols::UInt16
    xpixel::UInt16
    ypixel::UInt16
end

"""
    Session

A child process whose stdin, stdout and stderr are a pseudo-terminal slave. The
parent holds the master side as a `Base.TTY`, which is read with `read_output!` (or with `readavailable`, which can lose the tail of the output; see `read_output!`)
and written with `write`.
"""
mutable struct Session
    master::Base.TTY
    masterfd::Cint
    process::Base.Process
    # Held while `read_output!` reads the master and while the master is closed, so that the
    # descriptor is not closed during a read. `closed` is set under the lock.
    const lock::ReentrantLock
    closed::Bool
end

# Throw a `SystemError` carrying `errno` if `rc` is -1. Must be called on the
# ccall result directly so that `errno` has not been changed by another call.
macro check_libc(rc, what)
    return quote
        if $(esc(rc)) == -1
            throw(SystemError($(esc(what)), Libc.errno()))
        end
    end
end

# The master is non-blocking, so that `read_output!` returns at once when no output is ready.
function open_master()
    fd = ccall(:posix_openpt, Cint, (Cint,), O_RDWR | O_NOCTTY | O_CLOEXEC)
    @check_libc fd "posix_openpt"
    flags = ccall(:fcntl, Cint, (Cint, Cint, Cint), fd, F_GETFL, 0)
    @check_libc flags "fcntl(F_GETFL)"
    @check_libc ccall(:fcntl, Cint, (Cint, Cint, Cint), fd, F_SETFL, flags | O_NONBLOCK) "fcntl(F_SETFL)"
    return fd
end

# Open the slave side of the pseudo-terminal whose master is `masterfd`.
# On error, `masterfd` is left open for the caller to close.
function open_slave(masterfd::Cint)
    @check_libc ccall(:grantpt, Cint, (Cint,), masterfd) "grantpt"
    @check_libc ccall(:unlockpt, Cint, (Cint,), masterfd) "unlockpt"
    namep = ccall(:ptsname, Ptr{UInt8}, (Cint,), masterfd)
    namep == C_NULL && throw(SystemError("ptsname", Libc.errno()))
    name = unsafe_string(namep)
    fd = ccall(:open, Cint, (Cstring, Cint), name, O_RDWR | O_NOCTTY | O_CLOEXEC)
    @check_libc fd "open($name)"
    return fd
end

function close_fd(fd::Cint)
    @check_libc ccall(:close, Cint, (Cint,), fd) "close"
    return nothing
end

function set_winsize!(fd::Cint, rows::Integer, cols::Integer)
    for (name, n) in (("rows", rows), ("cols", cols))
        0 <= n <= typemax(UInt16) || throw(ArgumentError("$name must be in 0:$(typemax(UInt16)), got $n"))
    end
    ws = Ref(Winsize(rows, cols, 0, 0))
    @check_libc ccall(:ioctl, Cint, (Cint, Culong, Ptr{Winsize}), fd, TIOCSWINSZ, ws) "ioctl(TIOCSWINSZ)"
    return nothing
end

function require_command(name::AbstractString)
    Sys.which(name) === nothing && throw(ErrorException("Pty sessions need the `$name` command, which was not found on PATH"))
    return nothing
end

# Return once `proc` has replaced `setsid` and `setpriv` with the command. Until then the
# parent-death signal is not set: `setpriv` sets it just before it execs the command, and a signal
# is not sent when the parent has already died. Returns early if the process has exited.
function wait_for_exec(proc::Base.Process)
    helpers = (realpath(Sys.which("setsid")), realpath(Sys.which("setpriv")))
    exe_link = "/proc/$(getpid(proc))/exe"
    while !process_exited(proc)
        exe = try
            readlink(exe_link)
        catch err
            # The /proc entry is gone once the process has exited and been reaped.
            err isa Base.IOError && err.code == Base.UV_ENOENT || rethrow()
            return nothing
        end
        exe in helpers || return nothing
        sleep(0.0005)
    end
    return nothing
end

"""
    spawn(cmd::Cmd; rows = 24, cols = 80) -> Session

Run `cmd` as `setsid -c cmd` with a new pseudo-terminal of `rows` by `cols`
characters as its stdin, stdout and stderr. The child is the session leader
and the terminal is its controlling terminal, so the byte `0x03` sent to the
session raises SIGINT in the child.

The child is sent SIGKILL when the Julia thread that called `spawn` exits,
which at the latest is when the Julia process exits, including when it is
killed with SIGKILL. The pid of the session, `getpid(s.process)`, is the pid
of `cmd`.

Throws `SystemError`, with the `errno` text, if a system call fails.
"""
function spawn(cmd::Cmd; rows::Integer = 24, cols::Integer = 80)
    Sys.islinux() || throw(ErrorException("Pty sessions are supported only on Linux"))
    require_command("setsid")
    require_command("setpriv")
    masterfd = open_master()
    slavefd = Cint(-1)
    master = nothing
    try
        slavefd = open_slave(masterfd)
        set_winsize!(slavefd, rows, cols)
        master = Base.TTY(RawFD(masterfd))
        # The parent-death signal is set by `setpriv`, which then execs `cmd`: `setsid` and `setpriv`
        # both exec, so no extra process remains. The master and slave descriptors are close-on-exec,
        # so when the parent dies and the kernel closes the master, the child's terminal hangs up and
        # the session leader gets SIGHUP.
        wrapped = Cmd(Cmd(["setsid", "-c", "setpriv", "--pdeathsig", "KILL", cmd.exec...]); env = cmd.env, dir = cmd.dir)
        proc = run(wrapped, RawFD(slavefd), RawFD(slavefd), RawFD(slavefd); wait = false)
        wait_for_exec(proc)
        return Session(master, masterfd, proc, ReentrantLock(), false)
    catch
        master === nothing ? close_fd(masterfd) : close(master)
        rethrow()
    finally
        # The parent does not use the slave. Closing it here means the master
        # reads end-of-file or EIO once the child has closed its copies.
        slavefd >= 0 && close_fd(slavefd)
    end
end

"""
    is_raw(s::Session) -> Bool

Whether the terminal that `s`'s child is attached to has line editing (`ICANON`) and echo (`ECHO`)
turned off, as a program that reads keystrokes itself, such as the Julia REPL at its prompt, sets
it. While this is false the kernel buffers and echoes the bytes written to `s`, and a program that
later switches to raw mode does not see them as separate keystrokes.

Throws `SystemError` if the terminal attributes cannot be read.
"""
function is_raw(s::Session)
    buf = zeros(UInt8, TERMIOS_BYTES)
    GC.@preserve buf begin
        @check_libc ccall(:tcgetattr, Cint, (Cint, Ptr{UInt8}), s.masterfd, buf) "tcgetattr"
    end
    lflag = reinterpret(UInt32, buf[TERMIOS_LFLAG_OFFSET+1:TERMIOS_LFLAG_OFFSET+4])[1]
    return lflag & (ICANON | ECHO) == 0
end

Base.write(s::Session, x) = write(s.master, x)
Base.readavailable(s::Session) = readavailable(s.master)
Base.isopen(s::Session) = isopen(s.master)

"""
    read_output!(s::Session, buf::Vector{UInt8}) -> Int

Read the child's output into `buf` with `read(2)`, without waiting. Returns the number of bytes read,
0 when no output is ready now, or -1 when the output has ended: the child's side of the terminal is
closed and everything it wrote has been read, or the session has been closed.

This bypasses libuv's `readavailable`, which stops at the hangup and leaves the tail of the output in
the kernel's buffer, so that a child which exits with unread output loses that output. Errors other
than the two ends throw `SystemError`.
"""
function read_output!(s::Session, buf::Vector{UInt8})
    isempty(buf) && throw(ArgumentError("the buffer for read_output! must not be empty"))
    lock(s.lock) do
        s.closed && return -1
        n = GC.@preserve buf ccall(:read, Cint, (Cint, Ptr{UInt8}, Csize_t), s.masterfd, buf, length(buf))
        n > 0 && return Int(n)
        n == 0 && return -1
        errno = Libc.errno()
        errno == Int(Libc.EAGAIN) && return 0
        errno == Int(Libc.EIO) && return -1
        throw(SystemError("read of the pty master", errno))
    end
end

"""
    resize!(s::Session, rows, cols)

Set the window size of the terminal. The child receives SIGWINCH and
`displaysize` in the child reflects the new size.
"""
function Base.resize!(s::Session, rows::Integer, cols::Integer)
    isopen(s) || throw(ArgumentError("cannot resize a closed Pty session"))
    set_winsize!(s.masterfd, rows, cols)
    return nothing
end

"""
    exit_status(s::Session) -> Int

Wait for the child to exit and return its exit code. Throws if the child was
terminated by a signal, naming the signal.
"""
function exit_status(s::Session)
    wait(s.process)
    p = s.process
    p.termsignal == 0 || error("Pty child was terminated by signal $(p.termsignal)")
    return p.exitcode
end

"""
    close(s::Session; timeout = 5)

End the session. If the child is still running, send Ctrl+D and wait up to
`timeout` seconds for it to exit, then send SIGKILL. The master is closed
in all cases. Closing the master hangs up the child's terminal, which sends
SIGHUP to the child; a child that ignores SIGHUP keeps running.
"""
function Base.close(s::Session; timeout::Real = 5)
    isopen(s) || return nothing
    try
        if !process_exited(s.process)
            # Fails if the child has already exited; the wait below covers that case.
            try
                write(s.master, CTRL_D)
            catch
            end
            timedwait(() -> process_exited(s.process), timeout; pollint = 0.02) === :timed_out &&
                kill(s.process, Base.SIGKILL)
            wait(s.process)
        end
    finally
        lock(s.lock) do
            s.closed = true
            close(s.master)
        end
    end
    return nothing
end

end # module Pty
